defmodule Editor.OpenFileCache do
  @moduledoc """
  Caches opened files in ETS and broadcasts file-open notifications.
  """

  use GenServer

  @table :editor_open_file_cache
  @topic "editor:open_files"

  defstruct [:path, :content, :byte_size, :opened_at, in_focus?: false]

  @type t :: %__MODULE__{
          path: String.t(),
          content: binary(),
          byte_size: non_neg_integer(),
          opened_at: DateTime.t(),
          in_focus?: boolean()
        }

  @type metadata :: %{
          path: String.t(),
          byte_size: non_neg_integer(),
          opened_at: DateTime.t(),
          in_focus?: boolean()
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Editor.PubSub, @topic)
  end

  @spec cache_file(String.t(), binary()) :: {:ok, t()} | {:error, :not_started}
  def cache_file(path, content) when is_binary(path) and is_binary(content) do
    opened_file = %__MODULE__{
      path: path,
      content: content,
      byte_size: byte_size(content),
      opened_at: DateTime.utc_now(),
      in_focus?: true
    }

    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:cache_file, opened_file})
    end
  end

  @spec focus_file(String.t()) :: {:ok, t()} | :error | {:error, :not_started}
  def focus_file(path) when is_binary(path) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:focus_file, path})
    end
  end

  @spec delete_file(String.t()) :: :ok | {:error, :not_started}
  def delete_file(path) when is_binary(path) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(__MODULE__, {:delete_file, path})
    end
  end

  @spec get(String.t()) :: {:ok, t()} | :error
  def get(path) when is_binary(path) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      table ->
        case :ets.lookup(table, path) do
          [{^path, opened_file}] -> {:ok, opened_file}
          [] -> :error
        end
    end
  end

  @spec list_files() :: [t()]
  def list_files do
    case :ets.whereis(@table) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.map(fn {_path, opened_file} -> opened_file end)
        |> Enum.sort_by(& &1.opened_at, DateTime)
    end
  end

  @spec file_metadata(t()) :: metadata()
  def file_metadata(%__MODULE__{} = opened_file) do
    Map.take(opened_file, [:path, :byte_size, :opened_at, :in_focus?])
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :protected,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:cache_file, %__MODULE__{} = opened_file}, _from, state) do
    focus_existing_files(opened_file.path)
    true = :ets.insert(@table, {opened_file.path, opened_file})
    broadcast_open_files_updated()

    {:reply, {:ok, opened_file}, state}
  end

  @impl true
  def handle_call({:focus_file, path}, _from, state) do
    case :ets.lookup(@table, path) do
      [{^path, opened_file}] ->
        focus_existing_files(path)
        focused_file = %{opened_file | in_focus?: true}
        true = :ets.insert(@table, {path, focused_file})
        broadcast_open_files_updated()

        {:reply, {:ok, focused_file}, state}

      [] ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_call({:delete_file, path}, _from, state) do
    :ets.delete(@table, path)
    broadcast_open_files_updated()

    {:reply, :ok, state}
  end

  defp focus_existing_files(focused_path) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {path, opened_file} ->
      true = :ets.insert(@table, {path, %{opened_file | in_focus?: path == focused_path}})
    end)
  end

  defp broadcast_open_files_updated do
    Phoenix.PubSub.broadcast(
      Editor.PubSub,
      @topic,
      {:open_files_updated, Enum.map(list_files(), &file_metadata/1)}
    )
  end
end
