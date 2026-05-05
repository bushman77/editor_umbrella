defmodule Llm do
  @moduledoc """
  Public API for interacting with the local llama-server instance.
  """

  alias Llm.Client
  alias Llm.ContextPack
  alias Llm.ProjectMemory
  alias Llm.LlamaServer

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

  def chat(message) when is_binary(message) do
    chat([%{role: "user", content: message}])
  end

  def chat(messages) when is_list(messages) do
    with :ok <- LlamaServer.ensure_running() do
      Client.chat(messages)
    end
  end

  def build_context(root_path, selected_file, question, opts \\ [])
      when is_binary(root_path) and is_binary(question) do
    related_files = Keyword.get(opts, :related_files, [])

    with {:ok, project_memory} <- ProjectMemory.Builder.build(root_path),
         {:ok, project_memory} <-
           ensure_selected_file_memory(project_memory, root_path, selected_file),
         {:ok, project_memory} <-
           ensure_related_files_memory(project_memory, root_path, related_files),
         extra_refs = refs_for_related_files(project_memory, root_path, related_files),
         pack <-
           ContextPack.Builder.build(project_memory, %{
             question: question,
             current_file: relative_selected_file(root_path, selected_file),
             extra_refs: extra_refs
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

  def status do
    LlamaServer.status()
  end

  def ready? do
    LlamaServer.ready?()
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

  defp refs_for_related_files(project_memory, root_path, related_files) do
    related_files
    |> normalize_related_files()
    |> Enum.flat_map(fn related_file ->
      project_memory
      |> ProjectMemory.refs_for_path(relative_selected_file(root_path, related_file))
    end)
  end

  defp normalize_related_files(related_files) when is_list(related_files) do
    related_files
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp normalize_related_files(_related_files), do: []

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
