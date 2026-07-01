defmodule Llm.ProjectMemory.Cache do
  @moduledoc """
  Caches project-memory snapshots by workspace root.

  The cache invalidates when the set of prompt-eligible files changes or when
  one of those files changes size or modification time. It keeps RAG requests
  from rebuilding the whole project-memory snapshot when the workspace is idle.
  """

  use GenServer

  alias Llm.ProjectMemory
  alias Llm.ProjectMemory.Builder
  alias Llm.Prompts

  @name __MODULE__
  @default_max_files 200

  @type cache_opts :: [
          project_id: String.t(),
          max_files: pos_integer(),
          chunk_lines: pos_integer(),
          chunk_overlap: non_neg_integer()
        ]

  @type cache_key :: {String.t(), term()}
  @type cache_entry :: %{
          signature: term(),
          project_memory: ProjectMemory.snapshot()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))
  end

  @spec get(String.t(), cache_opts()) :: {:ok, ProjectMemory.snapshot()} | {:error, term()}
  def get(root_path, opts \\ []) when is_binary(root_path) and is_list(opts) do
    if pid = Process.whereis(@name) do
      GenServer.call(pid, {:get, root_path, opts}, :infinity)
    else
      Builder.build(root_path, opts)
    end
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(root_path) when is_binary(root_path) do
    call_if_running({:invalidate, root_path})
  end

  @spec clear() :: :ok
  def clear do
    call_if_running(:clear)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get, root_path, opts}, _from, state) do
    expanded_root = Path.expand(root_path)

    with {:ok, signature} <- project_signature(expanded_root, opts) do
      key = cache_key(expanded_root, opts)

      case Map.get(state, key) do
        %{signature: ^signature, project_memory: project_memory} ->
          {:reply, {:ok, project_memory}, state}

        _stale_or_missing ->
          case Builder.build(expanded_root, opts) do
            {:ok, project_memory} ->
              entry = %{signature: signature, project_memory: project_memory}
              {:reply, {:ok, project_memory}, Map.put(state, key, entry)}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:invalidate, root_path}, _from, state) do
    expanded_root = Path.expand(root_path)

    state =
      state
      |> Enum.reject(fn {{root, _opts_signature}, _entry} -> root == expanded_root end)
      |> Map.new()

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  defp call_if_running(message) do
    if pid = Process.whereis(@name) do
      GenServer.call(pid, message, :infinity)
    else
      :ok
    end
  end

  @spec cache_key(String.t(), cache_opts()) :: cache_key()
  defp cache_key(expanded_root, opts) do
    {expanded_root, cache_opts_signature(opts)}
  end

  defp cache_opts_signature(opts) do
    opts
    |> Keyword.take([:project_id, :max_files, :chunk_lines, :chunk_overlap])
    |> Enum.sort()
  end

  defp project_signature(expanded_root, opts) do
    if File.dir?(expanded_root) do
      signature =
        expanded_root
        |> Prompts.list_files_recursive()
        |> Enum.filter(&Prompts.wanted_file?/1)
        |> Enum.take(Keyword.get(opts, :max_files, @default_max_files))
        |> Enum.map(&file_signature(expanded_root, &1))

      {:ok, signature}
    else
      {:error, "Root path is not a directory: #{expanded_root}"}
    end
  end

  defp file_signature(expanded_root, path) do
    relative_path = Path.relative_to(path, expanded_root)

    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        {relative_path, stat.size, stat.mtime}

      {:error, reason} ->
        {relative_path, {:error, reason}}
    end
  end
end
