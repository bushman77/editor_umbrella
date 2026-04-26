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

  def build_context(root_path, selected_file, question)
      when is_binary(root_path) and is_binary(question) do
    with {:ok, project_memory} <- ProjectMemory.Builder.build(root_path),
         {:ok, project_memory} <-
           ensure_selected_file_memory(project_memory, root_path, selected_file),
         pack <-
           ContextPack.Builder.build(project_memory, %{
             question: question,
             current_file: relative_selected_file(root_path, selected_file)
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
