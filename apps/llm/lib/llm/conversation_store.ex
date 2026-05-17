defmodule Llm.ConversationStore do
  @moduledoc """
  DETS-backed persistence for `Llm.Conversation` snapshots.

  The conversation GenServer keeps ETS as the fast runtime cache. This module is
  the durable backing store used to restore conversation state after a restart.
  """

  use GenServer

  @table __MODULE__

  @type snapshot :: Llm.Conversation.snapshot()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec all() :: [snapshot()]
  def all do
    call_if_started(:all, [])
  end

  @spec get(String.t()) :: snapshot() | nil
  def get(conversation_id) when is_binary(conversation_id) do
    call_if_started({:get, conversation_id}, nil)
  end

  @spec put(snapshot()) :: :ok
  def put(%{id: conversation_id} = snapshot) when is_binary(conversation_id) do
    call_if_started({:put, snapshot}, :ok)
  end

  @spec delete(String.t()) :: :ok
  def delete(conversation_id) when is_binary(conversation_id) do
    call_if_started({:delete, conversation_id}, :ok)
  end

  @impl true
  def init(opts) do
    path = store_path(opts)
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, type: :set, file: String.to_charlist(path)) do
      {:ok, @table} -> {:ok, %{path: path}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:all, _from, state) do
    snapshots =
      @table
      |> :dets.match_object({:_, :_})
      |> case do
        {:error, _reason} -> []
        rows -> Enum.map(rows, fn {_id, snapshot} -> snapshot end)
      end

    {:reply, snapshots, state}
  end

  def handle_call({:get, conversation_id}, _from, state) do
    snapshot =
      case :dets.lookup(@table, conversation_id) do
        [{^conversation_id, snapshot}] -> snapshot
        [] -> nil
      end

    {:reply, snapshot, state}
  end

  def handle_call({:put, snapshot}, _from, state) do
    :ok = :dets.insert(@table, {snapshot.id, snapshot})
    :ok = :dets.sync(@table)

    {:reply, :ok, state}
  end

  def handle_call({:delete, conversation_id}, _from, state) do
    :ok = :dets.delete(@table, conversation_id)
    :ok = :dets.sync(@table)

    {:reply, :ok, state}
  end

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  defp call_if_started(message, fallback) do
    case Process.whereis(__MODULE__) do
      nil -> fallback
      pid -> GenServer.call(pid, message, :infinity)
    end
  end

  defp store_path(opts) do
    opts[:path]
    |> Kernel.||(Application.get_env(:llm, :conversation_store_path))
    |> Kernel.||(default_store_path())
    |> Path.expand()
  end

  defp default_store_path do
    data_home =
      System.get_env("XDG_DATA_HOME") ||
        case System.get_env("HOME") do
          nil -> Path.join(System.tmp_dir!(), "editor_umbrella")
          home -> Path.join([home, ".local", "share"])
        end

    Path.join([data_home, "editor_umbrella", "llm_conversations.dets"])
  end
end
