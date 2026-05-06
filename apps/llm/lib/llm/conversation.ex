defmodule Llm.Conversation do
  @moduledoc """
  Server-side conversation memory for editor LLM sessions.

  The table stores recent user turns and an optional summary. Assistant answers
  are excluded by default so hallucinated code does not become future source
  truth. It does not store RAG snippets; project context is rebuilt for each
  request.
  """

  use GenServer

  @table __MODULE__
  @default_recent_limit 12
  @max_messages 48

  @type id :: String.t()
  @type message :: %{role: String.t(), content: String.t()}
  @type snapshot :: %{
          id: id(),
          project_id: String.t() | nil,
          current_file: String.t() | nil,
          messages: [message()],
          summary: String.t() | nil,
          updated_at: DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec new_id(String.t() | nil) :: id()
  def new_id(project_id \\ nil) do
    unique = System.unique_integer([:positive, :monotonic])
    prefix = project_id |> to_string() |> hash_id()

    "conversation:#{prefix}:#{unique}"
  end

  @spec ensure(id(), keyword() | map()) :: snapshot()
  def ensure(conversation_id, attrs \\ []) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:ensure, conversation_id, Map.new(attrs)}, :infinity)
  end

  @spec get(id()) :: snapshot() | nil
  def get(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:get, conversation_id}, :infinity)
  end

  @spec recent_messages(id(), pos_integer(), keyword()) :: [message()]
  def recent_messages(conversation_id, limit \\ @default_recent_limit, opts \\ [])
      when is_binary(conversation_id) and is_integer(limit) and limit > 0 and is_list(opts) do
    GenServer.call(__MODULE__, {:recent_messages, conversation_id, limit, opts}, :infinity)
  end

  @spec summary(id()) :: String.t() | nil
  def summary(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:summary, conversation_id}, :infinity)
  end

  @spec record_turn(id(), String.t(), String.t() | nil, keyword() | map()) :: snapshot()
  def record_turn(conversation_id, question, response, attrs \\ [])
      when is_binary(conversation_id) and is_binary(question) and
             (is_binary(response) or is_nil(response)) do
    GenServer.call(
      __MODULE__,
      {:record_turn, conversation_id, question, response, Map.new(attrs)},
      :infinity
    )
  end

  @spec put_summary(id(), String.t() | nil) :: snapshot()
  def put_summary(conversation_id, summary) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:put_summary, conversation_id, summary}, :infinity)
  end

  @spec delete(id()) :: :ok
  def delete(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:delete, conversation_id}, :infinity)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure, conversation_id, attrs}, _from, state) do
    snapshot = ensure_snapshot(conversation_id, attrs)
    {:reply, snapshot, state}
  end

  def handle_call({:get, conversation_id}, _from, state) do
    {:reply, lookup(conversation_id), state}
  end

  def handle_call({:recent_messages, conversation_id, limit, opts}, _from, state) do
    messages =
      conversation_id
      |> lookup()
      |> case do
        nil -> []
        snapshot -> recent_snapshot_messages(snapshot, limit, opts)
      end

    {:reply, messages, state}
  end

  def handle_call({:summary, conversation_id}, _from, state) do
    summary =
      conversation_id
      |> lookup()
      |> case do
        nil -> nil
        snapshot -> snapshot.summary
      end

    {:reply, summary, state}
  end

  def handle_call({:record_turn, conversation_id, question, response, attrs}, _from, state) do
    snapshot = ensure_snapshot(conversation_id, attrs)

    messages =
      snapshot.messages
      |> Kernel.++(turn_messages(question, response, attrs))
      |> Enum.take(-@max_messages)

    snapshot =
      snapshot
      |> Map.merge(conversation_attrs(attrs))
      |> Map.put(:messages, messages)
      |> Map.put(:updated_at, DateTime.utc_now())

    insert(snapshot)
    {:reply, snapshot, state}
  end

  def handle_call({:put_summary, conversation_id, summary}, _from, state) do
    snapshot =
      conversation_id
      |> ensure_snapshot(%{})
      |> Map.put(:summary, normalize_summary(summary))
      |> Map.put(:updated_at, DateTime.utc_now())

    insert(snapshot)
    {:reply, snapshot, state}
  end

  def handle_call({:delete, conversation_id}, _from, state) do
    :ets.delete(@table, conversation_id)
    {:reply, :ok, state}
  end

  defp ensure_snapshot(conversation_id, attrs) do
    case lookup(conversation_id) do
      nil ->
        snapshot =
          %{
            id: conversation_id,
            project_id: Map.get(attrs, :project_id),
            current_file: Map.get(attrs, :current_file),
            messages: [],
            summary: normalize_summary(Map.get(attrs, :summary)),
            updated_at: DateTime.utc_now()
          }

        insert(snapshot)
        snapshot

      snapshot ->
        snapshot =
          snapshot
          |> Map.merge(conversation_attrs(attrs))
          |> Map.put(:updated_at, DateTime.utc_now())

        insert(snapshot)
        snapshot
    end
  end

  defp conversation_attrs(attrs) do
    attrs
    |> Map.take([:project_id, :current_file])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp turn_messages(question, response, attrs) do
    user_message = %{role: "user", content: String.trim(question)}

    if Map.get(attrs, :store_assistant?, false) and is_binary(response) do
      [user_message, %{role: "assistant", content: String.trim(response)}]
    else
      [user_message]
    end
  end

  defp recent_snapshot_messages(snapshot, limit, opts) do
    snapshot.messages
    |> maybe_retain_assistant_messages(Keyword.get(opts, :include_assistant?, false))
    |> Enum.take(-limit)
  end

  defp maybe_retain_assistant_messages(messages, true), do: messages

  defp maybe_retain_assistant_messages(messages, false) do
    Enum.filter(messages, fn message -> Map.get(message, :role) == "user" end)
  end

  defp lookup(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, snapshot}] -> snapshot
      [] -> nil
    end
  end

  defp insert(snapshot) do
    :ets.insert(@table, {snapshot.id, snapshot})
  end

  defp normalize_summary(summary) when is_binary(summary) do
    summary
    |> String.trim()
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  defp normalize_summary(_summary), do: nil

  defp hash_id(value) do
    value
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
