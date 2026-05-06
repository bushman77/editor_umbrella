defmodule Llm.Codex do
  @moduledoc """
  GenServer boundary for future Codex-oriented LLM workflows.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def state(server \\ __MODULE__) do
    GenServer.call(server, :state, :infinity)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end
end
