defmodule Llm.Rag do
  @moduledoc """
  Retrieval augmented generation context boundary for editor requests.

  This module coordinates the retrieval side of an editor-assisted LLM request:
  it builds project memory, makes sure request-specific files are represented in
  that memory, retrieves context refs, and returns a prompt-ready context pack.
  """

  alias Llm.ContextPack
  alias Llm.ProjectMemory

  @type context :: %{
          mode: :file | :folder,
          root_path: String.t(),
          question: String.t(),
          primary_path: String.t() | nil,
          files: [map()],
          messages: [map()],
          pack: ContextPack.t(),
          project_memory: ProjectMemory.snapshot()
        }

  @spec build_context(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, context()} | {:error, term()}
  def build_context(root_path, selected_file, question, opts \\ [])
      when is_binary(root_path) and is_binary(question) and is_list(opts) do
    related_files = Keyword.get(opts, :related_files, [])
    related_file_specs =
      normalize_related_file_specs(Keyword.get(opts, :related_file_specs, []))

    related_files = related_file_paths(related_files, related_file_specs)
    open_files = Keyword.get(opts, :open_files, [])
    token_budget = Keyword.get(opts, :token_budget)
    conversation_id = Keyword.get(opts, :conversation_id)
    recent_messages = Keyword.get(opts, :recent_messages, [])
    conversation_summary = Keyword.get(opts, :conversation_summary)

    with {:ok, project_memory} <- ProjectMemory.Builder.build(root_path),
         {:ok, project_memory} <-
           ensure_selected_file_memory(project_memory, root_path, selected_file),
         {:ok, project_memory} <-
           ensure_related_files_memory(project_memory, root_path, related_files),
         {:ok, project_memory} <-
           ensure_related_files_memory(project_memory, root_path, open_files),
         extra_refs = refs_for_related_files(project_memory, root_path, related_files, related_file_specs),
         open_refs = refs_for_open_files(project_memory, root_path, open_files),
         pack <-
           ContextPack.Builder.build(project_memory, %{
             question: question,
             current_file: relative_selected_file(root_path, selected_file),
             related_file_specs: relativize_related_file_specs(root_path, related_file_specs),
             extra_refs: extra_refs,
             open_refs: open_refs,
             token_budget: token_budget,
             conversation_id: conversation_id,
             recent_messages: recent_messages,
             conversation_summary: conversation_summary
           }) do
      {:ok,
       %{
         mode: context_mode(selected_file),
         root_path: Path.expand(root_path),
         question: question,
         primary_path: selected_file,
         files: context_files(pack),
         messages: pack.messages,
         pack: pack,
         project_memory: project_memory
       }}
    end
  end

  defp context_mode(nil), do: :folder
  defp context_mode(_selected_file), do: :file

  defp ensure_selected_file_memory(project_memory, _root_path, nil), do: {:ok, project_memory}

  defp ensure_selected_file_memory(project_memory, root_path, selected_file)
       when is_binary(selected_file) do
    relative_path = relative_selected_file(root_path, selected_file)

    if ProjectMemory.file_known?(project_memory, relative_path) do
      {:ok, project_memory}
    else
      case ProjectMemory.Builder.build_file(root_path, selected_file) do
        {:ok, %{summary: summary, chunks: chunks}} ->
          project_memory =
            project_memory
            |> ProjectMemory.put_file_summary(summary)
            |> ProjectMemory.put_file_chunks(chunks)

          {:ok, project_memory}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_related_files_memory(project_memory, root_path, related_files) do
    project_memory =
      related_files
      |> normalize_related_files()
      |> Enum.reduce(project_memory, fn related_file, project_memory ->
        relative_path = relative_selected_file(root_path, related_file)

        cond do
          ProjectMemory.file_known?(project_memory, relative_path) ->
            project_memory

          not File.regular?(related_file) ->
            project_memory

          true ->
            case ProjectMemory.Builder.build_file(root_path, related_file) do
              {:ok, %{summary: summary, chunks: chunks}} ->
                project_memory
                |> ProjectMemory.put_file_summary(summary)
                |> ProjectMemory.put_file_chunks(chunks)

              {:error, _reason} ->
                project_memory
            end
        end
      end)

    {:ok, project_memory}
  end

  defp refs_for_related_files(_project_memory, _root_path, _related_files, [_spec | _rest]) do
    []
  end

  defp refs_for_related_files(project_memory, root_path, related_files, []) do
    related_files
    |> normalize_related_files()
    |> Enum.flat_map(fn related_file ->
      project_memory
      |> ProjectMemory.refs_for_path(relative_selected_file(root_path, related_file))
    end)
  end

  defp refs_for_open_files(project_memory, root_path, open_files) do
    open_files
    |> normalize_related_files()
    |> Enum.flat_map(fn open_file ->
      project_memory
      |> ProjectMemory.refs_for_path(relative_selected_file(root_path, open_file))
      |> Enum.map(&mark_open_file_ref/1)
    end)
  end

  defp mark_open_file_ref(ref) do
    %{ref | metadata: Map.put(ref.metadata, :source, :open_file)}
  end

  defp normalize_related_files(related_files) when is_list(related_files) do
    related_files
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_related_files(_related_files), do: []

  defp normalize_related_file_specs(related_file_specs) when is_list(related_file_specs) do
    related_file_specs
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn spec ->
      case Map.get(spec, :path) || Map.get(spec, "path") do
        path when is_binary(path) ->
          [
            %{
              path: Path.expand(path),
              relationship:
                Map.get(spec, :relationship) || Map.get(spec, "relationship") || "related",
              included?: Map.get(spec, :included?) || Map.get(spec, "included?") || false,
              functions: Map.get(spec, :functions) || Map.get(spec, "functions") || []
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.path)
  end

  defp normalize_related_file_specs(_related_file_specs), do: []

  defp related_file_paths(related_files, []), do: related_files
  defp related_file_paths(_related_files, related_file_specs),
    do: Enum.map(related_file_specs, & &1.path)

  defp relativize_related_file_specs(root_path, related_file_specs) do
    Enum.map(related_file_specs, fn spec ->
      %{spec | path: relative_selected_file(root_path, spec.path)}
    end)
  end

  defp relative_selected_file(_root_path, nil), do: nil

  defp relative_selected_file(root_path, selected_file) when is_binary(selected_file) do
    selected_file
    |> Path.expand()
    |> Path.relative_to(Path.expand(root_path))
  end

  defp context_files(%ContextPack{} = pack) do
    pack.refs
    |> Enum.map(& &1.path)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.map(&%{path: &1, content: ""})
  end
end
