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

  # ---------------------------------------------------------------------------
  # Model / llama.cpp paths
  # ---------------------------------------------------------------------------

  # @model_path "~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-GGUF/snapshots/b82fb7382639d97b38fa7672e526c760c2fb358e/Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf"
  @model_path "~/models/qwen2.5-coder-7b-instruct-gguf/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
  @llama_dir "~/llama.cpp"
  @llama_server_path "build/bin/llama-server"

  # ---------------------------------------------------------------------------
  # Server binding
  # ---------------------------------------------------------------------------

  @host "127.0.0.1"
  @port 8000

  # ---------------------------------------------------------------------------
  # llama-server tuning
  #
  # RTX 4060 / 8 GB VRAM friendly defaults:
  #
  #   * 16k context instead of 65k
  #   * 2k generation limit instead of 8k
  #   * GPU layer offload set to auto
  #   * Flash Attention enabled
  #
  # If you want the old heavier settings, change:
  #
  #   @context_size 65_536
  #   @max_tokens 8_192
  # ---------------------------------------------------------------------------

  @flash_attention "on"
  @gpu_layers "auto"
  @parallel_slots 1
  @context_size 65_536
  @max_tokens 8_192
  @batch_size 2_048
  @micro_batch_size 512

  # ---------------------------------------------------------------------------
  # Startup / readiness timing
  # ---------------------------------------------------------------------------

  @startup_wait_ms 30_000
  @poll_interval_ms 500
  @tcp_connect_timeout_ms 1_000

  defstruct port: nil,
            started_by_app?: false,
            last_exit_status: nil

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_running do
    GenServer.call(__MODULE__, :ensure_running, :infinity)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def ready? do
    running?()
  end

  def running? do
    case :gen_tcp.connect(tcp_host(), @port, [:binary, active: false], @tcp_connect_timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  def wait_until_ready(timeout_ms \\ @startup_wait_ms) do
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

  defp server_args do
    [
      "-m",
      model_path(),
      "--jinja",
      "--host",
      @host,
      "--port",
      to_string(@port),
      "-fa",
      @flash_attention,
      "-ngl",
      @gpu_layers,
      "-np",
      to_string(@parallel_slots),
      "-c",
      to_string(@context_size),
      "-n",
      to_string(@max_tokens),
      "-b",
      to_string(@batch_size),
      "-ub",
      to_string(@micro_batch_size)
    ]
  end

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
        Process.sleep(@poll_interval_ms)
        do_wait_until_ready(deadline_ms)
    end
  end

  # ---------------------------------------------------------------------------
  # Path / formatting helpers
  # ---------------------------------------------------------------------------

  defp model_path do
    Path.expand(@model_path)
  end

  defp llama_dir do
    Path.expand(@llama_dir)
  end

  defp executable_path do
    Path.join(llama_dir(), @llama_server_path)
  end

  defp endpoint do
    "#{@host}:#{@port}"
  end

  defp tcp_host do
    String.to_charlist(@host)
  end

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
