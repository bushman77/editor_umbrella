defmodule Llm.OpenCodeACP do
  @moduledoc """
  Owns a long-lived `opencode acp` subprocess and provides minimal ACP
  JSON-RPC request/response support.

  Sessions are tracked per workspace (`cwd`) so different projects do not
  trample each other.
  """

  use GenServer

  require Logger

  @default_cmd "opencode"
  @default_args ["acp"]
  @max_output_lines 200
  @jsonrpc_version "2.0"
  @protocol_version 1

  @type request_id :: non_neg_integer()

  @type session_entry :: %{
          required(:session_id) => String.t(),
          required(:session) => map(),
          required(:available_commands) => [map()]
        }

  @type pending_request :: %{
          required(:from) => GenServer.from(),
          required(:method) => String.t(),
          optional(:cwd) => String.t()
        }

  @type state :: %{
          required(:cmd) => String.t(),
          required(:args) => [String.t()],
          required(:cwd) => String.t(),
          required(:port) => port() | nil,
          required(:status) => :starting | :running | :stopped | :error,
          required(:error) => String.t() | nil,
          required(:last_exit_status) => non_neg_integer() | nil,
          required(:output) => [String.t()],
          required(:buffer) => binary(),
          required(:next_id) => request_id(),
          required(:pending) => %{optional(request_id()) => pending_request()},
          required(:initialized?) => boolean(),
          required(:initialize_result) => map() | nil,
          required(:sessions_by_cwd) => %{optional(String.t()) => session_entry()},
          required(:session_id_to_cwd) => %{optional(String.t()) => String.t()},
          required(:turn_text_by_cwd) => %{optional(String.t()) => String.t()},
          required(:latest_agent_text) => String.t(),
          required(:last_stop_reason) => String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec state(GenServer.server()) :: state()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state, :infinity)
  end

  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__) do
    GenServer.call(server, :running?, :infinity)
  end

  @spec initialized?(GenServer.server()) :: boolean()
  def initialized?(server \\ __MODULE__) do
    GenServer.call(server, :initialized?, :infinity)
  end

  @spec session_id(String.t(), GenServer.server()) :: String.t() | nil
  def session_id(cwd, server \\ __MODULE__) when is_binary(cwd) do
    GenServer.call(server, {:session_id, cwd}, :infinity)
  end

  @spec session(String.t(), GenServer.server()) :: map() | nil
  def session(cwd, server \\ __MODULE__) when is_binary(cwd) do
    GenServer.call(server, {:session, cwd}, :infinity)
  end

  @spec available_commands(String.t(), GenServer.server()) :: [map()]
  def available_commands(cwd, server \\ __MODULE__) when is_binary(cwd) do
    GenServer.call(server, {:available_commands, cwd}, :infinity)
  end

  @spec latest_agent_text(GenServer.server()) :: String.t()
  def latest_agent_text(server \\ __MODULE__) do
    GenServer.call(server, :latest_agent_text, :infinity)
  end

  @spec last_stop_reason(GenServer.server()) :: String.t() | nil
  def last_stop_reason(server \\ __MODULE__) do
    GenServer.call(server, :last_stop_reason, :infinity)
  end

  @spec initialize(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def initialize(server \\ __MODULE__) do
    request(
      server,
      "initialize",
      %{
        "protocolVersion" => @protocol_version,
        "clientCapabilities" => %{},
        "clientInfo" => %{
          "name" => "editor_umbrella",
          "title" => "Editor Umbrella",
          "version" => "0.1.0"
        }
      }
    )
  end

  @spec new_session(keyword()) :: {:ok, map()} | {:error, term()}
  def new_session(opts) when is_list(opts) do
    new_session(__MODULE__, opts)
  end

  @spec new_session(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def new_session(server, opts) when is_list(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    mcp_servers = Keyword.get(opts, :mcp_servers, [])

    request(
      server,
      "session/new",
      %{
        "cwd" => cwd,
        "mcpServers" => mcp_servers
      },
      %{cwd: cwd}
    )
  end

  @spec reset_session(String.t(), GenServer.server()) :: :ok
  def reset_session(cwd, server \\ __MODULE__) when is_binary(cwd) do
    GenServer.call(server, {:reset_session, cwd}, :infinity)
  end

  @spec prompt(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(text, opts \\ []) when is_binary(text) and is_list(opts) do
    prompt(__MODULE__, text, opts)
  end

  @spec prompt(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(server, text, opts) when is_binary(text) and is_list(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    GenServer.call(server, {:prompt, cwd, text}, :infinity)
  end

  @spec request(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(method, params) when is_binary(method) and is_map(params) do
    request(__MODULE__, method, params, %{})
  end

  @spec request(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def request(server, method, params)
      when is_binary(method) and is_map(params) do
    request(server, method, params, %{})
  end

  @spec request(GenServer.server(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def request(server, method, params, meta)
      when is_binary(method) and is_map(params) and is_map(meta) do
    GenServer.call(server, {:request, method, params, meta}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :boot)
    {:ok, build_state(opts)}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:running?, _from, state) do
    {:reply, running_state?(state), state}
  end

  @impl true
  def handle_call(:initialized?, _from, state) do
    {:reply, state.initialized?, state}
  end

  @impl true
  def handle_call({:session_id, cwd}, _from, state) do
    {:reply, session_id_for(state, cwd), state}
  end

  @impl true
  def handle_call({:session, cwd}, _from, state) do
    {:reply, session_for(state, cwd), state}
  end

  @impl true
  def handle_call({:available_commands, cwd}, _from, state) do
    {:reply, available_commands_for(state, cwd), state}
  end

  @impl true
  def handle_call(:latest_agent_text, _from, state) do
    {:reply, state.latest_agent_text, state}
  end

  @impl true
  def handle_call(:last_stop_reason, _from, state) do
    {:reply, state.last_stop_reason, state}
  end

  @impl true
  def handle_call({:reset_session, cwd}, _from, state) do
    {:reply, :ok, drop_session(state, cwd)}
  end

  @impl true
  def handle_call({:prompt, cwd, text}, from, state) do
    session_id = session_id_for(state, cwd)

    cond do
      not running_state?(state) ->
        {:reply, {:error, :not_running}, state}

      is_nil(session_id) ->
        {:reply, {:error, :no_session}, state}

      true ->
        params = %{
          "sessionId" => session_id,
          "prompt" => [
            %{
              "type" => "text",
              "text" => text
            }
          ]
        }

        state = put_in(state, [:turn_text_by_cwd, cwd], "")

        dispatch_request(state, from, "session/prompt", params, %{cwd: cwd})
    end
  end

  @impl true
  def handle_call({:request, method, params, meta}, from, state) do
    dispatch_request(state, from, method, params, meta)
  end

  @impl true
  def handle_info(:boot, state) do
    {:noreply, start_port(state)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    data = IO.iodata_to_binary(data)
    Logger.debug("[OpenCode ACP] #{inspect(data)}")

    state =
      state
      |> push_output(data)
      |> append_and_process_buffer(data)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("OpenCode ACP exited with status #{status}")

    Enum.each(state.pending, fn {_id, %{from: from}} ->
      GenServer.reply(from, {:error, {:acp_exited, status}})
    end)

    {:noreply, reset_runtime_state(state, %{last_exit_status: status, status: :stopped})}
  end

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("OpenCode ACP port exit: #{inspect(reason)}")

    Enum.each(state.pending, fn {_id, %{from: from}} ->
      GenServer.reply(from, {:error, {:port_exit, reason}})
    end)

    {:noreply, reset_runtime_state(state, %{error: inspect(reason), status: :stopped})}
  end

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, state) do
    maybe_close_port(state.port)
    :ok
  end

  defp build_state(opts) do
    %{
      cmd: Keyword.get(opts, :cmd, Application.get_env(:llm, :opencode_cmd, @default_cmd)),
      args: Keyword.get(opts, :args, Application.get_env(:llm, :opencode_args, @default_args)),
      cwd: Keyword.get(opts, :cwd, Application.get_env(:llm, :opencode_cwd, File.cwd!())),
      port: nil,
      status: :starting,
      error: nil,
      last_exit_status: nil,
      output: [],
      buffer: "",
      next_id: 1,
      pending: %{},
      initialized?: false,
      initialize_result: nil,
      sessions_by_cwd: %{},
      session_id_to_cwd: %{},
      turn_text_by_cwd: %{},
      latest_agent_text: "",
      last_stop_reason: nil
    }
  end

  defp running_state?(state) do
    state.status == :running and is_port(state.port)
  end

  defp start_port(state) do
    case System.find_executable(state.cmd) do
      nil ->
        %{state | port: nil, status: :error, error: "Could not find executable: #{state.cmd}"}

      executable ->
        Logger.info(
          "Starting OpenCode ACP with #{inspect(executable)} #{Enum.join(state.args, " ")} in #{state.cwd}"
        )

        port =
          Port.open(
            {:spawn_executable, executable},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, state.args},
              {:cd, state.cwd}
            ]
          )

        %{state | port: port, status: :running, error: nil, buffer: ""}
    end
  end

  defp dispatch_request(state, from, method, params, meta) do
    cond do
      not running_state?(state) ->
        {:reply, {:error, :not_running}, state}

      true ->
        id = state.next_id

        payload = %{
          "jsonrpc" => @jsonrpc_version,
          "id" => id,
          "method" => method,
          "params" => params
        }

        case Jason.encode(payload) do
          {:ok, encoded} ->
            Port.command(state.port, encoded <> "\n")

            pending =
              Map.put(
                state.pending,
                id,
                Map.merge(%{from: from, method: method}, meta)
              )

            {:noreply, %{state | next_id: id + 1, pending: pending}}

          {:error, reason} ->
            {:reply, {:error, {:encode_failed, reason}}, state}
        end
    end
  end

  defp append_and_process_buffer(state, chunk) do
    combined = state.buffer <> chunk
    parts = :binary.split(combined, "\n", [:global])

    {complete_lines, remainder} =
      case Enum.reverse(parts) do
        [last | rest_rev] -> {Enum.reverse(rest_rev), last}
        [] -> {[], ""}
      end

    processed_state =
      Enum.reduce(complete_lines, %{state | buffer: ""}, fn line, acc ->
        process_line(acc, line)
      end)

    %{processed_state | buffer: remainder}
  end

  defp process_line(state, ""), do: state

  defp process_line(state, line) do
    clean_line = String.trim(line)

    if clean_line == "" do
      state
    else
      case Jason.decode(clean_line) do
        {:ok, %{"id" => id, "result" => _} = payload} ->
          handle_rpc_response(state, id, payload)

        {:ok, %{"id" => id, "error" => _} = payload} ->
          handle_rpc_response(state, id, payload)

        {:ok, %{"method" => method, "id" => id} = payload} ->
          handle_inbound_request(state, id, method, payload)

        {:ok, %{"method" => _} = payload} ->
          handle_notification(state, payload)

        {:ok, payload} ->
          Logger.debug("OpenCode ACP unclassified payload: #{inspect(payload)}")
          state

        {:error, reason} ->
          Logger.warning("OpenCode ACP JSON decode failed: #{inspect(reason)}")
          %{state | error: "json_decode_failed"}
      end
    end
  end

  defp handle_rpc_response(state, id, %{"result" => result}) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        Logger.debug("OpenCode ACP response for unknown id #{inspect(id)}")
        %{state | pending: pending}

      {%{from: from, method: method} = pending_meta, pending} ->
        {reply, new_state} = rpc_success_reply(state, method, result, pending_meta)
        GenServer.reply(from, reply)
        %{new_state | pending: pending}
    end
  end

  defp handle_rpc_response(state, id, %{"error" => error}) do
    case Map.pop(state.pending, id) do
      {nil, pending} ->
        Logger.debug("OpenCode ACP error for unknown id #{inspect(id)}: #{inspect(error)}")
        %{state | pending: pending}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, error})
        %{state | pending: pending}
    end
  end

  defp rpc_success_reply(state, "initialize", result, _pending_meta) do
    {{:ok, result}, %{state | initialized?: true, initialize_result: result}}
  end

  defp rpc_success_reply(state, "session/new", result, %{cwd: cwd}) do
    session_id = Map.get(result, "sessionId")
    {{:ok, result}, put_session(state, cwd, session_id, result)}
  end

  defp rpc_success_reply(state, "session/prompt", result, %{cwd: cwd}) do
    text = Map.get(state.turn_text_by_cwd, cwd, "")

    reply =
      {:ok,
       %{
         "stopReason" => Map.get(result, "stopReason"),
         "text" => text
       }}

    new_state =
      state
      |> update_in([:turn_text_by_cwd], &Map.delete(&1, cwd))
      |> Map.put(:latest_agent_text, text)
      |> Map.put(:last_stop_reason, Map.get(result, "stopReason"))

    {reply, new_state}
  end

  defp rpc_success_reply(state, _method, result, _pending_meta) do
    {{:ok, result}, state}
  end

  defp handle_notification(state, %{
         "method" => "session/update",
         "params" => %{
           "sessionId" => session_id,
           "update" => %{
             "sessionUpdate" => "available_commands_update",
             "availableCommands" => commands
           }
         }
       })
       when is_list(commands) do
    case Map.fetch(state.session_id_to_cwd, session_id) do
      {:ok, cwd} ->
        new_state = update_session_commands(state, cwd, commands)
        Logger.debug("OpenCode ACP available commands updated for #{cwd}: #{inspect(commands)}")
        new_state

      :error ->
        state
    end
  end

  defp handle_notification(state, %{
         "method" => "session/update",
         "params" => %{
           "sessionId" => session_id,
           "update" => %{
             "sessionUpdate" => "agent_message_chunk",
             "content" => %{
               "type" => "text",
               "text" => text
             }
           }
         }
       })
       when is_binary(text) do
    case Map.fetch(state.session_id_to_cwd, session_id) do
      {:ok, cwd} ->
        if Map.has_key?(state.turn_text_by_cwd, cwd) do
          update_in(state, [:turn_text_by_cwd, cwd], &((&1 || "") <> text))
        else
          state
        end

      :error ->
        state
    end
  end

  defp handle_notification(state, payload) do
    Logger.debug("OpenCode ACP notification: #{inspect(payload)}")
    state
  end

  defp handle_inbound_request(state, id, method, payload) do
    Logger.warning("Unhandled ACP inbound request #{method}: #{inspect(payload)}")

    response = %{
      "jsonrpc" => @jsonrpc_version,
      "id" => id,
      "error" => %{
        "code" => -32601,
        "message" => "Method not implemented by editor client"
      }
    }

    case Jason.encode(response) do
      {:ok, encoded} ->
        Port.command(state.port, encoded <> "\n")
        state

      {:error, reason} ->
        Logger.warning("Failed to encode ACP error response: #{inspect(reason)}")
        state
    end
  end

  defp session_id_for(state, cwd) do
    get_in(state.sessions_by_cwd, [cwd, :session_id])
  end

  defp session_for(state, cwd) do
    get_in(state.sessions_by_cwd, [cwd, :session])
  end

  defp available_commands_for(state, cwd) do
    get_in(state.sessions_by_cwd, [cwd, :available_commands]) || []
  end

  defp put_session(state, cwd, session_id, session) do
    session_entry = %{
      session_id: session_id,
      session: session,
      available_commands: available_commands_for(state, cwd)
    }

    state
    |> put_in([:sessions_by_cwd, cwd], session_entry)
    |> maybe_put_session_lookup(session_id, cwd)
  end

  defp update_session_commands(state, cwd, commands) do
    case Map.fetch(state.sessions_by_cwd, cwd) do
      {:ok, entry} ->
        put_in(state, [:sessions_by_cwd, cwd], %{entry | available_commands: commands})

      :error ->
        state
    end
  end

  defp maybe_put_session_lookup(state, session_id, cwd) when is_binary(session_id) do
    put_in(state, [:session_id_to_cwd, session_id], cwd)
  end

  defp maybe_put_session_lookup(state, _session_id, _cwd), do: state

  defp drop_session(state, cwd) do
    session_id = session_id_for(state, cwd)

    state
    |> update_in([:sessions_by_cwd], &Map.delete(&1, cwd))
    |> update_in([:session_id_to_cwd], fn lookup ->
      if is_binary(session_id), do: Map.delete(lookup, session_id), else: lookup
    end)
    |> update_in([:turn_text_by_cwd], &Map.delete(&1, cwd))
  end

  defp push_output(state, data) do
    lines =
      data
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim_trailing(&1, "\r"))

    output =
      (state.output ++ lines)
      |> Enum.take(-@max_output_lines)

    %{state | output: output}
  end

  defp reset_runtime_state(state, overrides) do
    Map.merge(
      %{
        state
        | port: nil,
          pending: %{},
          initialized?: false,
          sessions_by_cwd: %{},
          session_id_to_cwd: %{},
          turn_text_by_cwd: %{},
          latest_agent_text: "",
          last_stop_reason: nil
      },
      overrides
    )
  end

  defp maybe_close_port(nil), do: :ok

  defp maybe_close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end
end
