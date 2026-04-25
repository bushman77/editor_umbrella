defmodule Llm.LlamaServer do
  @moduledoc """
  Manages the local llama-server process and readiness checks.
  """

  use GenServer
  require Logger
  @host '127.0.0.1'
  @port 8000
  @startup_wait_ms 30_000
  @poll_interval_ms 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_running do
    GenServer.call(__MODULE__, :ensure_running, :infinity)
  end

  def running? do
    case :gen_tcp.connect(@host, @port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  def ready? do
    running?()
  end

  def wait_until_ready(timeout_ms \\ @startup_wait_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_ready(deadline_ms)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      started_by_app?: false,
      last_exit_status: nil
    }

    {:ok, state, {:continue, :ensure_started}}
  end

  @impl true
  def handle_continue(:ensure_started, state) do
    cond do
      running?() ->
        Logger.info("llama-server is already running on 127.0.0.1:8000")
        {:noreply, state}

      true ->
        new_state = %{state | port: start_llama_server(), started_by_app?: true}

        case wait_until_ready() do
          :ok ->
            Logger.info("llama-server is up and ready on 127.0.0.1:8000")
            {:noreply, new_state}

          {:error, reason} ->
            Logger.error("llama-server failed to become ready: #{inspect(reason)}")
            {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_call(:ensure_running, _from, state) do
    cond do
      ready?() ->
        {:reply, :ok, state}

      state.port != nil ->
        {:reply, wait_until_ready(), state}

      true ->
        new_state = %{state | port: start_llama_server(), started_by_app?: true}
        {:reply, wait_until_ready(), new_state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running?: running?(),
       ready?: ready?(),
       started_by_app?: state.started_by_app?,
       last_exit_status: state.last_exit_status
     }, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, %{state | port: nil, last_exit_status: status}}
  end

  @impl true
  def handle_info({port, {:data, _data}}, %{port: port} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp do_wait_until_ready(deadline_ms) do
    cond do
      ready?() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        {:error, :startup_timeout}

      true ->
        Process.sleep(@poll_interval_ms)
        do_wait_until_ready(deadline_ms)
    end
  end

  defp start_llama_server do
    model_path =
      Path.expand(
        "~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-GGUF/snapshots/b82fb7382639d97b38fa7672e526c760c2fb358e/Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf"
      )

    llama_dir = Path.expand("~/llama.cpp")
    executable = Path.join(llama_dir, "build/bin/llama-server")

    args = [
      "-m",
      model_path,
      "--jinja",
      "--host",
      "127.0.0.1",
      "--port",
      "8000",
      "-fa",
      "on",
      "-np",
      "1",
      "-c",
      "32768",
      "-n",
      "4096"
    ]

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: args,
      cd: llama_dir
    ])
  end
end
