defmodule Llm.ProjectMemory do
  @moduledoc """
  Coordinates project-scoped memory used to build compact LLM context packs.

  This module is the app-owned memory boundary. It tracks file summaries,
  file chunks, and context refs so the prompt builder can select and rehydrate
  only the most relevant material for each request.
  """

  alias Llm.ContextRef
  alias Llm.ProjectMemory.FileChunk
  alias Llm.ProjectMemory.FileSummary

  @type project_id :: String.t()
  @type file_path :: String.t()

  @type file_memory :: %{
          summary: FileSummary.t() | nil,
          chunks: [FileChunk.t()]
        }

  @type snapshot :: %{
          project_id: project_id() | nil,
          files: %{optional(file_path()) => file_memory()},
          pinned_refs: [ContextRef.t()],
          recent_refs: [ContextRef.t()]
        }

  @spec new_snapshot(keyword() | map()) :: snapshot()
  def new_snapshot(attrs \\ %{})

  def new_snapshot(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new_snapshot()
  end

  def new_snapshot(attrs) when is_map(attrs) do
    %{
      project_id: Map.get(attrs, :project_id),
      files: Map.get(attrs, :files, %{}),
      pinned_refs: normalize_refs(Map.get(attrs, :pinned_refs, [])),
      recent_refs: normalize_refs(Map.get(attrs, :recent_refs, []))
    }
  end

  @spec put_file_summary(snapshot(), FileSummary.t()) :: snapshot()
  def put_file_summary(snapshot, %FileSummary{} = summary) do
    memory =
      snapshot.files
      |> Map.get(summary.path, empty_file_memory())
      |> Map.put(:summary, summary)

    put_in(snapshot, [:files, summary.path], memory)
  end

  @spec put_file_chunk(snapshot(), FileChunk.t()) :: snapshot()
  def put_file_chunk(snapshot, %FileChunk{} = chunk) do
    memory = Map.get(snapshot.files, chunk.path, empty_file_memory())
    existing_chunks = Map.get(memory, :chunks, [])

    updated_chunks =
      existing_chunks
      |> Enum.reject(fn existing ->
        existing.chunk_index == chunk.chunk_index
      end)
      |> Kernel.++([chunk])
      |> Enum.sort_by(& &1.chunk_index)

    put_in(snapshot, [:files, chunk.path], %{memory | chunks: updated_chunks})
  end

  @spec put_file_chunks(snapshot(), [FileChunk.t()]) :: snapshot()
  def put_file_chunks(snapshot, chunks) when is_list(chunks) do
    Enum.reduce(chunks, snapshot, fn chunk, acc ->
      put_file_chunk(acc, chunk)
    end)
  end

  @spec get_file_summary(snapshot(), file_path()) :: FileSummary.t() | nil
  def get_file_summary(snapshot, path) when is_binary(path) do
    get_in(snapshot, [:files, path, :summary])
  end

  @spec get_file_chunks(snapshot(), file_path()) :: [FileChunk.t()]
  def get_file_chunks(snapshot, path) when is_binary(path) do
    get_in(snapshot, [:files, path, :chunks]) || []
  end

  @spec list_file_paths(snapshot()) :: [file_path()]
  def list_file_paths(snapshot) do
    snapshot.files
    |> Map.keys()
    |> Enum.sort()
  end

  @spec add_pinned_ref(snapshot(), ContextRef.t() | map() | keyword()) :: snapshot()
  def add_pinned_ref(snapshot, %ContextRef{} = ref) do
    %{snapshot | pinned_refs: dedupe_refs(snapshot.pinned_refs ++ [ref])}
  end

  def add_pinned_ref(snapshot, attrs) when is_map(attrs) or is_list(attrs) do
    add_pinned_ref(snapshot, ContextRef.new(:pinned_file, attrs))
  end

  @spec add_recent_ref(snapshot(), ContextRef.t() | map() | keyword()) :: snapshot()
  def add_recent_ref(snapshot, %ContextRef{} = ref) do
    %{snapshot | recent_refs: dedupe_refs(snapshot.recent_refs ++ [ref])}
  end

  def add_recent_ref(snapshot, attrs) when is_map(attrs) or is_list(attrs) do
    add_recent_ref(snapshot, ContextRef.new(:file_chunk, attrs))
  end

  @spec refs_for_path(snapshot(), file_path()) :: [ContextRef.t()]
  def refs_for_path(snapshot, path) when is_binary(path) do
    summary_ref =
      case get_file_summary(snapshot, path) do
        %FileSummary{} = summary -> [FileSummary.to_context_ref(summary)]
        nil -> []
      end

    chunk_refs =
      snapshot
      |> get_file_chunks(path)
      |> Enum.map(&FileChunk.to_context_ref/1)

    summary_ref ++ chunk_refs
  end

  @spec file_known?(snapshot(), file_path()) :: boolean()
  def file_known?(snapshot, path) when is_binary(path) do
    Map.has_key?(snapshot.files, path)
  end

  @spec project_summary(snapshot()) :: map()
  def project_summary(snapshot) do
    %{
      project_id: snapshot.project_id,
      file_count: map_size(snapshot.files),
      pinned_ref_count: length(snapshot.pinned_refs),
      recent_ref_count: length(snapshot.recent_refs)
    }
  end

  defp normalize_refs(refs) do
    refs
    |> Enum.map(fn
      %ContextRef{} = ref -> ref
      attrs when is_map(attrs) -> ContextRef.new(:file_chunk, attrs)
      attrs when is_list(attrs) -> ContextRef.new(:file_chunk, attrs)
    end)
    |> dedupe_refs()
  end

  defp dedupe_refs(refs) do
    Enum.uniq_by(refs, fn ref ->
      {ref.type, ref.path, ref.chunk_id, ref.start_line, ref.end_line, ref.label}
    end)
  end

  defp empty_file_memory do
    %{summary: nil, chunks: []}
  end
end
