defmodule Llm.LlamaServer do
  @moduledoc """
  Starts and monitors a local `llama-server` process.

  Responsibilities:

    * Start `llama-server` when the app boots.
    * Reuse an already-running server if one exists.
    * Wait until the server accepts TCP connections.
    * Report basic runtime status.

  This module owns the OS process only when it starts it itself.
  """

  use GenServer
  require Logger

  @default_model_name "Qwen/Qwen3-4B-Instruct-2507"
  @default_model_path "~/models/qwen3-4b-instruct-2507/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf"
  @default_llama_dir "~/llama.cpp"
  @default_llama_server_path "build/bin/llama-server"
  @default_host "127.0.0.1"
  @default_port 8000
  @default_jinja true
  @default_reasoning "auto"
  @default_flash_attention "on"
  @default_gpu_layers "auto"
  @default_parallel_slots 1
  @default_context_size 32_768
  @default_max_tokens 16_384
  @default_batch_size 2_048
  @default_micro_batch_size 512
  @default_startup_wait_ms 30_000
  @default_poll_interval_ms 500
  @default_tcp_connect_timeout_ms 1_000

  defstruct port: nil,
            started_by_app?: false,
            last_exit_status: nil

  @type status :: %{
          running?: boolean(),
          ready?: boolean(),
          started_by_app?: boolean(),
          last_exit_status: non_neg_integer() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_running() :: :ok | {:error, :startup_timeout}
  def ensure_running do
    GenServer.call(__MODULE__, :ensure_running, :infinity)
  end

  @spec status() :: status()
  def status do
    GenServer.call(__MODULE__, :status, :infinity)
  end

  @spec ready?() :: boolean()
  def ready? do
    running?()
  end

  @spec running?() :: boolean()
  def running? do
    case :gen_tcp.connect(tcp_host(), port(), [:binary, active: false], tcp_connect_timeout_ms()) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  @spec wait_until_ready(timeout()) :: :ok | {:error, :startup_timeout}
  def wait_until_ready(timeout_ms \\ startup_wait_ms()) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_until_ready(deadline_ms)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :ensure_started}}
  end

  @impl true
  def handle_continue(:ensure_started, state) do
    {:noreply, ensure_started(state)}
  end

  @impl true
  def handle_call(:ensure_running, _from, state) do
    state = ensure_started(state)

    {:reply, wait_until_ready(), state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      running?: running?(),
      ready?: ready?(),
      started_by_app?: state.started_by_app?,
      last_exit_status: state.last_exit_status
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({port, {:exit_status, exit_status}}, %{port: port} = state) do
    Logger.warning("llama-server exited with status #{exit_status}")

    new_state = %{state | port: nil, last_exit_status: exit_status}

    {:noreply, new_state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    log_server_output(data)

    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Startup helpers
  # ---------------------------------------------------------------------------

  defp ensure_started(state) do
    cond do
      ready?() ->
        Logger.info("llama-server is already running on #{endpoint()}")

        state

      state.port != nil ->
        Logger.info("llama-server process is already starting")

        state

      true ->
        Logger.info("starting llama-server on #{endpoint()}")

        %{state | port: start_llama_server(), started_by_app?: true}
    end
  end

  defp start_llama_server do
    Port.open({:spawn_executable, executable_path()}, [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: server_args(),
      cd: llama_dir()
    ])
  end

  @doc false
  @spec server_args() :: [String.t()]
  def server_args do
    sampling = Application.get_env(:llm, :sampling, [])

    options = [
      {"--model", model_path()},
      {"--alias", model_alias()},
      {"--jinja", Application.get_env(:llm, :jinja, true)},
      {"--reasoning", reasoning()},
      {"--reasoning-format", reasoning_format()},
      {"--host", host()},
      {"--port", port()},
      {"--flash-attn", flash_attention()},
      {"--gpu-layers", gpu_layers()},
      {"--parallel", parallel_slots()},
      {"--ctx-size", context_size()},
      {"--n-predict", max_tokens()},
      {"--temp", sampling[:temperature]},
      {"--top-p", sampling[:top_p]},
      {"--top-k", sampling[:top_k]},
      {"--min-p", sampling[:min_p]},
      {"--presence-penalty", sampling[:presence_penalty]},
      {"--batch-size", batch_size()},
      {"--ubatch-size", micro_batch_size()}
    ]

    Enum.flat_map(options, &to_argv/1) ++ Application.get_env(:llm, :extra_args, [])
  end

  # nil / false -> omitted, true -> bare flag, anything else -> flag + value
  defp to_argv({_flag, nil}), do: []
  defp to_argv({_flag, false}), do: []
  defp to_argv({flag, true}), do: [flag]
  defp to_argv({flag, value}), do: [flag, to_string(value)]

  # ---------------------------------------------------------------------------
  # Readiness helpers
  # ---------------------------------------------------------------------------

  defp do_wait_until_ready(deadline_ms) do
    cond do
      ready?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:error, :startup_timeout}

      true ->
        Process.sleep(poll_interval_ms())
        do_wait_until_ready(deadline_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # Path / formatting helpers
  # ---------------------------------------------------------------------------

  @spec model_path() :: String.t()
  def model_path do
    :llm
    |> Application.get_env(:model, @default_model_path)
    |> Path.expand()
  end

  defp model_alias do
    Application.get_env(
      :llm,
      :alias,
      Application.get_env(:llm, :model_name, @default_model_name)
    )
  end

  @spec base_url() :: String.t()
  def base_url do
    "http://#{host()}:#{port()}"
  end

  defp llama_dir do
    :llm
    |> Application.get_env(:llama_dir, @default_llama_dir)
    |> Path.expand()
  end

  defp executable_path do
    Path.join(llama_dir(), llama_server_path())
  end

  defp endpoint do
    "#{host()}:#{port()}"
  end

  defp tcp_host do
    host()
    |> to_string()
    |> String.to_charlist()
  end

  defp llama_server_path do
    Application.get_env(:llm, :llama_server_path, @default_llama_server_path)
  end

  defp host do
    Application.get_env(:llm, :host, @default_host)
  end

  defp port do
    Application.get_env(:llm, :port, @default_port)
  end

  defp jinja_args do
    case Application.get_env(:llm, :jinja, @default_jinja) do
      true -> ["--jinja"]
      false -> ["--no-jinja"]
      _other -> []
    end
  end

  defp reasoning do
    Application.get_env(:llm, :reasoning, @default_reasoning)
  end

  defp reasoning_format do
    Application.get_env(:llm, :reasoning_format)
  end

  defp flash_attention do
    Application.get_env(:llm, :flash_attention, @default_flash_attention)
  end

  defp gpu_layers do
    Application.get_env(:llm, :gpu_layers, @default_gpu_layers)
  end

  defp parallel_slots do
    Application.get_env(:llm, :parallel_slots, @default_parallel_slots)
  end

  defp context_size do
    Application.get_env(:llm, :context_size, @default_context_size)
  end

  defp max_tokens do
    Application.get_env(:llm, :max_tokens, @default_max_tokens)
  end

  defp temperature do
    Application.get_env(:llm, :temperature)
  end

  defp top_p do
    Application.get_env(:llm, :top_p)
  end

  defp top_k do
    Application.get_env(:llm, :top_k)
  end

  defp min_p do
    Application.get_env(:llm, :min_p)
  end

  defp presence_penalty do
    Application.get_env(:llm, :presence_penalty)
  end

  defp batch_size do
    Application.get_env(:llm, :batch_size, @default_batch_size)
  end

  defp micro_batch_size do
    Application.get_env(:llm, :micro_batch_size, @default_micro_batch_size)
  end

  defp startup_wait_ms do
    Application.get_env(:llm, :startup_wait_ms, @default_startup_wait_ms)
  end

  defp poll_interval_ms do
    Application.get_env(:llm, :poll_interval_ms, @default_poll_interval_ms)
  end

  defp tcp_connect_timeout_ms do
    Application.get_env(:llm, :tcp_connect_timeout_ms, @default_tcp_connect_timeout_ms)
  end

  defp flag_arg(_flag, nil), do: []
  defp flag_arg(_flag, ""), do: []
  defp flag_arg(flag, value), do: [flag, to_string(value)]

  defp log_server_output(data) do
    data
    |> String.trim()
    |> case do
      "" ->
        :ok

      line ->
        Logger.debug("[llama-server] #{line}")
    end
  end
end
