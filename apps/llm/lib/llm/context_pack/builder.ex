defmodule Llm.ContextPack.Builder do
  @moduledoc """
  Builds compact prompt-ready context packs from project memory and request-time
  editor context.

  This module owns context selection and prompt assembly. Project memory can keep
  a broad view of the codebase, while this builder chooses the small subset that
  should be sent to the model for a single request.
  """

  alias Llm.ContextPack
  alias Llm.ContextRef
  alias Llm.ProjectMemory
  alias Llm.ProjectMemory.FileChunk
  alias Llm.ProjectMemory.FileSummary
  alias Llm.Prompts

  @default_token_budget 8_192
  @default_recent_message_limit 6
  @default_chunk_limit 6
  @default_summary_limit 8
  @refactor_keywords ["refactor", "rewrite", "clean up", "improve", "restructure"]

  @type build_opts :: %{
          optional(:conversation_id) => String.t(),
          optional(:project_id) => String.t(),
          optional(:question) => String.t(),
          optional(:current_file) => String.t(),
          optional(:selection) => map(),
          optional(:recent_messages) => Prompts.messages(),
          optional(:conversation_summary) => String.t(),
          optional(:pinned_refs) => [ContextRef.t()],
          optional(:extra_refs) => [ContextRef.t()],
          optional(:token_budget) => pos_integer()
        }

  @spec build(ProjectMemory.snapshot(), build_opts()) :: ContextPack.t()
  def build(project_memory, opts) when is_map(project_memory) and is_map(opts) do
    question = Map.get(opts, :question, "")
    current_file = Map.get(opts, :current_file)
    token_budget = Map.get(opts, :token_budget, @default_token_budget)
    recent_messages = Map.get(opts, :recent_messages, [])
    conversation_summary = Map.get(opts, :conversation_summary)
    selection = Map.get(opts, :selection)

    refs =
      project_memory
      |> collect_refs(current_file, opts)
      |> dedupe_refs()

    summaries =
      refs
      |> summary_lines()
      |> Enum.take(@default_summary_limit)

    messages =
      build_messages(
        project_memory,
        question,
        current_file,
        selection,
        conversation_summary,
        recent_messages,
        refs,
        summaries
      )

    ContextPack.new(
      conversation_id: Map.get(opts, :conversation_id),
      project_id: Map.get(opts, :project_id) || project_memory.project_id,
      question: question,
      current_file: current_file,
      selection: selection,
      token_budget: token_budget,
      estimated_tokens: estimate_tokens(messages),
      messages: messages,
      refs: refs,
      summaries: summaries,
      metadata: %{
        recent_message_count: length(recent_messages),
        conversation_summary?: present?(conversation_summary),
        ref_count: length(refs)
      }
    )
  end

  @spec retrieve_refs(ProjectMemory.snapshot(), String.t(), String.t() | nil) :: [ContextRef.t()]
  def retrieve_refs(project_memory, question, current_file)
      when is_map(project_memory) and is_binary(question) do
    module_refs = refs_for_mentioned_modules(project_memory, question)
    file_refs = refs_for_mentioned_files(project_memory, question)
    current_file_related_refs =
      if test_question?(question) do
        []
      else
        refs_related_to_current_file(project_memory, current_file)
      end

    test_refs = refs_for_associated_tests(project_memory, question, current_file)

    module_refs
    |> Kernel.++(file_refs)
    |> Kernel.++(current_file_related_refs)
    |> Kernel.++(test_refs)
    |> dedupe_refs()
  end

  defp collect_refs(project_memory, current_file, opts) do
    pinned_refs =
      project_memory.pinned_refs
      |> Kernel.++(normalize_refs(Map.get(opts, :pinned_refs, [])))

    extra_refs = normalize_refs(Map.get(opts, :extra_refs, []))

    current_file_refs =
      case current_file do
        path when is_binary(path) -> ProjectMemory.refs_for_path(project_memory, path)
        _ -> []
      end

    retrieved_refs =
      project_memory
      |> retrieve_refs(Map.get(opts, :question, ""), current_file)
      |> Enum.reject(fn ref ->
        Enum.any?(current_file_refs, &same_ref?(&1, ref))
      end)

    current_file_refs ++ pinned_refs ++ extra_refs ++ retrieved_refs
  end

  defp refs_for_mentioned_modules(project_memory, question) do
    question
    |> extract_module_names()
    |> Enum.flat_map(fn module_name ->
      project_memory.files
      |> Enum.flat_map(fn {_path, memory} ->
        summary = Map.get(memory, :summary)

        if match_summary_module?(summary, module_name) do
          [FileSummary.to_context_ref(summary)]
        else
          []
        end
      end)
    end)
  end

  defp refs_for_mentioned_files(project_memory, question) do
    question
    |> extract_file_mentions()
    |> Enum.flat_map(fn mentioned ->
      project_memory.files
      |> Enum.flat_map(fn {path, memory} ->
        if String.contains?(path, mentioned) do
          refs_for_file_memory(memory, @default_chunk_limit)
        else
          []
        end
      end)
    end)
  end

  defp refs_related_to_current_file(_project_memory, nil), do: []

  defp refs_related_to_current_file(project_memory, current_file) when is_binary(current_file) do
    current_dir = Path.dirname(current_file)

    project_memory.files
    |> Enum.flat_map(fn {path, memory} ->
      cond do
        path == current_file ->
          []

        Path.dirname(path) == current_dir ->
          refs_for_file_memory(memory, 2)

        true ->
          []
      end
    end)
  end

  defp refs_for_associated_tests(_project_memory, _question, nil), do: []

  defp refs_for_associated_tests(project_memory, question, current_file)
       when is_binary(question) and is_binary(current_file) do
    if test_question?(question) do
      candidate_paths = associated_test_paths(current_file)

      refs =
        candidate_paths
        |> Enum.flat_map(&refs_for_memory_path(project_memory, &1, 2))

      case refs do
        [] ->
          project_memory
          |> fallback_test_paths(current_file)
          |> Enum.take(4)
          |> Enum.flat_map(&refs_for_memory_path(project_memory, &1, 1))

        refs ->
          refs
      end
    else
      []
    end
  end

  defp test_question?(question) do
    normalized = String.downcase(question)

    Regex.match?(
      ~r/\b(test|tests|testing|unit tests?|associated tests?|coverage|specs?)\b/,
      normalized
    )
  end

  defp associated_test_paths("apps/" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [app, "lib", lib_path] ->
        [
          "apps/#{app}/test/#{test_path_for(lib_path)}",
          "apps/#{app}/test/#{app}_test.exs"
        ]

      _ ->
        []
    end
  end

  defp associated_test_paths("lib/" <> lib_path) do
    app_name =
      lib_path
      |> String.split("/", parts: 2)
      |> List.first()

    [
      "test/#{test_path_for(lib_path)}",
      "test/#{app_name}_test.exs"
    ]
  end

  defp associated_test_paths(_current_file), do: []

  defp test_path_for(lib_path) do
    cond do
      String.ends_with?(lib_path, ".ex") ->
        String.replace_suffix(lib_path, ".ex", "_test.exs")

      String.ends_with?(lib_path, ".exs") ->
        String.replace_suffix(lib_path, ".exs", "_test.exs")

      true ->
        lib_path <> "_test.exs"
    end
  end

  defp fallback_test_paths(project_memory, "apps/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [app, _path] -> test_paths_with_prefix(project_memory, "apps/#{app}/test/")
      _ -> []
    end
  end

  defp fallback_test_paths(project_memory, _current_file) do
    test_paths_with_prefix(project_memory, "test/")
  end

  defp test_paths_with_prefix(project_memory, prefix) do
    project_memory.files
    |> Map.keys()
    |> Enum.filter(fn path ->
      String.starts_with?(path, prefix) and String.ends_with?(path, "_test.exs")
    end)
    |> Enum.sort()
  end

  defp refs_for_memory_path(project_memory, path, chunk_limit) do
    case Map.get(project_memory.files, path) do
      nil -> []
      memory -> refs_for_file_memory(memory, chunk_limit)
    end
  end

  defp refs_for_file_memory(memory, chunk_limit) do
    summary_refs =
      case Map.get(memory, :summary) do
        %FileSummary{} = summary -> [FileSummary.to_context_ref(summary)]
        _ -> []
      end

    chunk_refs =
      memory
      |> Map.get(:chunks, [])
      |> Enum.take(chunk_limit)
      |> Enum.map(&FileChunk.to_context_ref/1)

    summary_refs ++ chunk_refs
  end

  defp build_messages(
         project_memory,
         question,
         current_file,
         selection,
         conversation_summary,
         recent_messages,
         refs,
         summaries
       ) do
    system_messages =
      [
        Prompts.system_message("""
        You are the local coding assistant for this project.

        Use the provided project memory, file refs, and exact snippets as your working context.
        Prefer the current file and current selection when they are present.
        """)
      ] ++
        maybe_refactor_contract_message(question) ++
        maybe_summary_message(conversation_summary) ++
        maybe_relevant_files_message(summaries) ++
        maybe_selection_message(current_file, selection) ++
        snippet_messages(project_memory, refs)

    system_messages ++ trim_recent_messages(recent_messages) ++ [Prompts.user_message(question)]
  end

  defp maybe_refactor_contract_message(question) do
    if refactor_question?(question) do
      [
        Prompts.system_message("""
        Refactor output contract:
        - Do not return the whole module or whole file.
        - Do not include module wrappers such as `defmodule ... do` or a final module `end`.
        - Do not include placeholder comments such as `# ... other code ...`.
        - Do not return unchanged functions, unchanged docs, unchanged types, or unchanged aliases.
        - Return only changed functions/docs or a unified diff.
        - If no safe code change is needed, respond exactly with: No code changes needed.

        Use exactly this shape:

        Assessment:
        <one short paragraph>

        Changed code:
        ```elixir
        <only changed functions/docs, or leave this section out when no code changes are needed>
        ```
        """)
      ]
    else
      []
    end
  end

  defp maybe_summary_message(summary) when is_binary(summary) and summary != "" do
    [
      Prompts.system_message("""
      Conversation summary:
      #{summary}
      """)
    ]
  end

  defp maybe_summary_message(_summary), do: []

  defp refactor_question?(question) when is_binary(question) do
    normalized = String.downcase(question)
    Enum.any?(@refactor_keywords, &String.contains?(normalized, &1))
  end

  defp refactor_question?(_question), do: false

  defp maybe_relevant_files_message([]), do: []

  defp maybe_relevant_files_message(summaries) do
    content =
      """
      Relevant files:
      #{Enum.map_join(summaries, "\n", &"- #{&1}")}
      """

    [Prompts.system_message(content)]
  end

  defp maybe_selection_message(_current_file, nil), do: []

  defp maybe_selection_message(current_file, selection) when is_map(selection) do
    content =
      """
      Current editor selection:
      File: #{current_file || "[unknown]"}
      #{format_selection(selection)}
      """

    [Prompts.system_message(content)]
  end

  defp snippet_messages(project_memory, refs) do
    refs
    |> Enum.flat_map(fn ref ->
      case ref.type do
        :file_chunk ->
          [Prompts.system_message(render_chunk_ref(project_memory, ref))]

        :current_file ->
          [Prompts.system_message(render_chunk_ref(project_memory, ref))]

        _ ->
          []
      end
    end)
  end

  defp render_chunk_ref(project_memory, ref) do
    content =
      chunk_content(project_memory, ref) || ref.summary || "[No snippet content available.]"

    """
    Context snippet:
    FILE: #{ref.path || "[unknown]"}
    LINES: #{format_lines(ref.start_line, ref.end_line)}
    ```#{language_for_ref(ref)}
    #{content}
    ```
    """
  end

  defp chunk_content(project_memory, %ContextRef{path: path} = ref) when is_binary(path) do
    project_memory
    |> ProjectMemory.get_file_chunks(path)
    |> Enum.find(&same_chunk?(&1, ref))
    |> case do
      %FileChunk{content: content} -> content
      nil -> nil
    end
  end

  defp chunk_content(_project_memory, _ref), do: nil

  defp same_chunk?(%FileChunk{} = chunk, %ContextRef{} = ref) do
    cond do
      is_binary(ref.chunk_id) and is_binary(chunk.id) ->
        chunk.id == ref.chunk_id

      true ->
        chunk.path == ref.path and chunk.start_line == ref.start_line and
          chunk.end_line == ref.end_line
    end
  end

  defp language_for_ref(%ContextRef{metadata: %{language: language}}) when is_binary(language) do
    language
  end

  defp language_for_ref(%ContextRef{path: path}) when is_binary(path) do
    FileSummary.infer_language(path)
  end

  defp language_for_ref(_ref), do: "text"

  defp format_lines(start_line, end_line)
       when is_integer(start_line) and is_integer(end_line),
       do: "#{start_line}-#{end_line}"

  defp format_lines(_start_line, _end_line), do: "[unknown]"

  defp format_selection(selection) do
    start_line = get_in(selection, [:start, :line]) || selection[:start_line]
    end_line = get_in(selection, [:end, :line]) || selection[:end_line]
    text = Map.get(selection, :text) || Map.get(selection, "text") || ""

    """
    Lines: #{format_lines(start_line, end_line)}
    ```text
    #{text}
    ```
    """
  end

  defp trim_recent_messages(messages) do
    Enum.take(messages, -@default_recent_message_limit)
  end

  defp summary_lines(refs) do
    refs
    |> Enum.map(&ContextRef.display_label/1)
    |> Enum.uniq()
  end

  defp extract_module_names(question) do
    ~r/\b(?:[A-Z][A-Za-z0-9_]*)(?:\.[A-Z][A-Za-z0-9_]*)+\b/
    |> Regex.scan(question)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  defp extract_file_mentions(question) do
    ~r/[\w\/\.-]+\.(?:ex|exs|heex|js|ts|tsx|json|md)\b/
    |> Regex.scan(question)
    |> Enum.map(fn [path] -> path end)
    |> Enum.uniq()
  end

  defp match_summary_module?(%FileSummary{module_names: module_names}, module_name) do
    module_name in module_names
  end

  defp match_summary_module?(_summary, _module_name), do: false

  defp normalize_refs(refs) do
    Enum.map(refs, fn
      %ContextRef{} = ref -> ref
      attrs when is_map(attrs) -> ContextRef.new(:file_chunk, attrs)
      attrs when is_list(attrs) -> ContextRef.new(:file_chunk, attrs)
    end)
  end

  defp dedupe_refs(refs) do
    Enum.uniq_by(refs, fn ref ->
      {ref.type, ref.path, ref.chunk_id, ref.start_line, ref.end_line, ref.label}
    end)
  end

  defp same_ref?(left, right) do
    {left.type, left.path, left.chunk_id, left.start_line, left.end_line} ==
      {right.type, right.path, right.chunk_id, right.start_line, right.end_line}
  end

  defp estimate_tokens(messages) do
    messages
    |> Enum.map(&Map.get(&1, :content, ""))
    |> Enum.join("\n")
    |> String.length()
    |> Kernel.div(4)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
