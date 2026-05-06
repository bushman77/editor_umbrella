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

  @default_token_budget 16_384
  @default_recent_message_limit 12
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
          optional(:open_refs) => [ContextRef.t()],
          optional(:related_file_specs) => [map()],
          optional(:token_budget) => pos_integer()
        }

  @spec build(ProjectMemory.snapshot(), build_opts()) :: ContextPack.t()
  def build(project_memory, opts) when is_map(project_memory) and is_map(opts) do
    question = Map.get(opts, :question, "")
    current_file = Map.get(opts, :current_file)
    token_budget = Map.get(opts, :token_budget) || @default_token_budget
    recent_messages = Map.get(opts, :recent_messages, [])
    conversation_summary = Map.get(opts, :conversation_summary)
    selection = Map.get(opts, :selection)
    related_file_specs = normalize_related_file_specs(Map.get(opts, :related_file_specs, []))

    refs =
      project_memory
      |> collect_refs(current_file, opts)
      |> dedupe_refs()
      |> trim_refs_to_budget(
        project_memory,
        question,
        current_file,
        selection,
        conversation_summary,
        recent_messages,
        token_budget
      )

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
        related_file_specs,
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
        ref_count: length(refs),
        related_file_specs: related_file_specs
      }
    )
  end

  @spec retrieve_refs(ProjectMemory.snapshot(), String.t(), String.t() | nil) :: [ContextRef.t()]
  def retrieve_refs(project_memory, question, current_file)
      when is_map(project_memory) and is_binary(question) do
    module_refs = refs_for_mentioned_modules(project_memory, question)
    file_refs = refs_for_mentioned_files(project_memory, question)
    auth_refs = refs_for_auth_context(project_memory, question)
    player_join_refs = refs_for_player_join_context(project_memory, question)

    current_file_related_refs =
      if test_question?(question) do
        []
      else
        refs_related_to_current_file(project_memory, current_file)
      end

    test_refs = refs_for_associated_tests(project_memory, question, current_file)

    module_refs
    |> Kernel.++(file_refs)
    |> Kernel.++(auth_refs)
    |> Kernel.++(player_join_refs)
    |> Kernel.++(current_file_related_refs)
    |> Kernel.++(test_refs)
    |> dedupe_refs()
  end

  defp collect_refs(project_memory, current_file, opts) do
    pinned_refs =
      project_memory.pinned_refs
      |> Kernel.++(normalize_refs(Map.get(opts, :pinned_refs, [])))

    extra_refs = normalize_refs(Map.get(opts, :extra_refs, []))
    open_refs = normalize_refs(Map.get(opts, :open_refs, []))
    related_file_spec_paths =
      opts
      |> Map.get(:related_file_specs, [])
      |> normalize_related_file_specs()
      |> Enum.map(& &1.path)
      |> MapSet.new()

    current_file_refs =
      case current_file do
        path when is_binary(path) -> ProjectMemory.refs_for_path(project_memory, path)
        _ -> []
      end

    retrieved_refs =
      project_memory
      |> retrieve_refs(Map.get(opts, :question, ""), current_file)
      |> Enum.reject(fn ref ->
        Enum.any?(current_file_refs, &same_ref?(&1, ref)) or
          MapSet.member?(related_file_spec_paths, ref.path)
      end)

    current_file_refs ++ pinned_refs ++ extra_refs ++ open_refs ++ retrieved_refs
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

  defp refs_for_auth_context(project_memory, question) do
    if auth_question?(question) do
      project_memory.files
      |> Enum.map(fn {path, memory} -> {auth_context_score(path, memory), memory} end)
      |> Enum.filter(fn {score, _memory} -> score > 0 end)
      |> Enum.sort_by(fn {score, memory} -> {-score, summary_path(memory)} end)
      |> Enum.take(6)
      |> Enum.flat_map(fn {_score, memory} -> refs_for_file_memory(memory, 2) end)
    else
      []
    end
  end

  defp auth_question?(question) do
    normalized = String.downcase(question)

    Regex.match?(
      ~r/\b(current_user|current user|logged in|login|session|auth|authenticated|current_scope|presence|user object|user who logged in)\b/,
      normalized
    )
  end

  defp auth_context_score(path, memory) do
    searchable =
      [
        path,
        memory |> Map.get(:summary) |> summary_text(),
        memory |> Map.get(:chunks, []) |> Enum.map_join("\n", & &1.content)
      ]
      |> Enum.join("\n")
      |> String.downcase()

    [
      {"current_user", 6},
      {"current_scope", 6},
      {"user_session", 5},
      {"log_in", 5},
      {"authenticated", 4},
      {"presence", 4},
      {"session", 3},
      {"user", 1}
    ]
    |> Enum.reduce(0, fn {term, weight}, score ->
      if String.contains?(searchable, term), do: score + weight, else: score
    end)
  end

  defp summary_text(%FileSummary{} = summary) do
    Enum.join([summary.path, summary.summary, Enum.join(summary.module_names || [], " ")], "\n")
  end

  defp summary_text(_summary), do: ""

  defp summary_path(memory) do
    case Map.get(memory, :summary) do
      %FileSummary{path: path} -> path
      _ -> ""
    end
  end

  defp refs_for_player_join_context(project_memory, question) do
    if player_join_question?(question) do
      project_memory.files
      |> Enum.map(fn {path, memory} -> {player_join_context_score(path, memory), memory} end)
      |> Enum.filter(fn {score, _memory} -> score > 0 end)
      |> Enum.sort_by(fn {score, memory} -> {-score, summary_path(memory)} end)
      |> Enum.take(8)
      |> Enum.flat_map(fn {_score, memory} -> refs_for_file_memory(memory, 3) end)
    else
      []
    end
  end

  defp player_join_question?(question) do
    normalized = String.downcase(question)

    Regex.match?(~r/\b(player|user|character|presence|lobby|gm|llm)\b/, normalized) and
      Regex.match?(
        ~r/\b(join|joins|joined|connect|connects|login|logged in|enters?)\b/,
        normalized
      )
  end

  defp player_join_context_score(path, memory) do
    searchable =
      [
        path,
        memory |> Map.get(:summary) |> summary_text(),
        memory |> Map.get(:chunks, []) |> Enum.map_join("\n", & &1.content)
      ]
      |> Enum.join("\n")
      |> String.downcase()

    [
      {"presence_diff", 8},
      {"phoenix.presence", 7},
      {"presence.track", 7},
      {"presence.list", 6},
      {"pubsub.subscribe", 6},
      {"endpoint.subscribe", 6},
      {"presence", 5},
      {"pubsub", 5},
      {"handle_info", 5},
      {"new_message", 4},
      {"topic", 4},
      {"track", 4},
      {"subscribe", 4},
      {"join", 3},
      {"connect", 3},
      {"player", 2},
      {"user", 1}
    ]
    |> Enum.reduce(0, fn {term, weight}, score ->
      if String.contains?(searchable, term), do: score + weight, else: score
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

  defp trim_refs_to_budget(
         refs,
         project_memory,
         question,
         current_file,
         selection,
         conversation_summary,
         recent_messages,
         token_budget
       ) do
    do_trim_refs_to_budget(
      refs,
      project_memory,
      question,
      current_file,
      selection,
      conversation_summary,
      recent_messages,
      token_budget
    )
  end

  defp do_trim_refs_to_budget(
         refs,
         project_memory,
         question,
         current_file,
         selection,
         conversation_summary,
         recent_messages,
         token_budget
       ) do
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
        [],
        refs,
        summaries
      )

    cond do
      estimate_tokens(messages) <= token_budget ->
        refs

      length(refs) <= 1 ->
        refs

      true ->
        refs
        |> Enum.drop(-1)
        |> do_trim_refs_to_budget(
          project_memory,
          question,
          current_file,
          selection,
          conversation_summary,
          recent_messages,
          token_budget
        )
    end
  end

  defp build_messages(
         project_memory,
         question,
         current_file,
         selection,
         conversation_summary,
         recent_messages,
         related_file_specs,
         refs,
         summaries
       ) do
    system_messages =
      [
        Prompts.system_message("""
        You are the local coding assistant for this project.

        Use the provided project memory, file refs, and exact snippets as your working context.
        Prefer the current file and current selection when they are present.

        Grounding rules:
        - Answer from the provided snippets and relevant-file summaries, not from generic framework knowledge alone.
        - When explaining project behavior, name the specific file paths, modules, functions, assigns, or plugs you used.
        - If the snippets do not show the requested object, assign, plug, or function, say that it is not present in the provided context and describe what file should be opened or searched next.
        - Do not invent application names, topics, assigns, or user/session fields that are not visible in the provided context.
        - Do not treat Phoenix Presence metadata as the logged-in/authenticated user object unless the snippets explicitly show that the metadata came from auth/session data.
        - Recent conversation messages are user intent/history only. They are not source-code evidence.
        - Existing code must be verified from current snippets, file refs, or relevant-file summaries, never from prior assistant answers.
        """)
      ] ++
        maybe_refactor_contract_message(question) ++
        maybe_review_contract_message(question, current_file) ++
        maybe_implementation_contract_message(question) ++
        maybe_summary_message(conversation_summary) ++
        maybe_current_file_message(current_file) ++
        maybe_related_file_specs_message(current_file, related_file_specs) ++
        maybe_relevant_files_message(summaries) ++
        maybe_selection_message(current_file, selection) ++
        snippet_messages(project_memory, refs)

    system_messages ++
      trim_recent_messages(recent_messages) ++
      final_answer_contract_messages(question) ++
      [Prompts.user_message(question)]
  end

  defp maybe_refactor_contract_message(question) do
    if refactor_question?(question) do
      [
        Prompts.system_message("""
        Refactor output contract:
        - The user is asking to refactor the current primary file. Do not refuse because a supporting snippet has unknown or partial line ranges.
        - Use the current selected file snippet as the target, and use supporting snippets only to preserve public behavior and dependencies.
        - If context is incomplete, still provide the safest behavior-preserving refactor you can infer from the visible primary-file code.
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

  defp maybe_review_contract_message(question, current_file) do
    if review_question?(question) and is_binary(current_file) do
      [
        Prompts.system_message("""
        Review request contract:
        - The user is asking you to review the current file: #{current_file}.
        - Do not ask which file to review.
        - Review the provided snippets for this current file first.
        - If the full file is not present, say that the review is limited to the provided snippets.
        - Lead with concrete findings, risks, or bugs. If none are visible, say that clearly.
        """)
      ]
    else
      []
    end
  end

  defp maybe_implementation_contract_message(question) do
    if implementation_question?(question) and not refactor_question?(question) do
      [
        Prompts.system_message("""
        Implementation request contract:
        - Distinguish existing code from proposed code.
        - Before saying a function, callback, or module already exists, verify it appears in the provided snippets.
        - Before saying code is called, check basic control flow. Code after a returned `{:noreply, ...}` or `{:reply, ...}` tuple in the same branch is unreachable.
        - Do not add or call new notification APIs such as `notify_user_login/2` unless the user explicitly asks for that API name or the snippets already define it.
        - If a suggested function does not exist in the snippets, label it as a new function to add.
        - Do not answer PubSub/event wiring questions by adding a standalone helper that nothing calls. Identify the existing event producer and the existing subscriber/consumer. If either side is missing from snippets, say which side is missing and do not provide a fake patch.
        - For join notifications, the change must be located at the observed join/presence/event boundary or at an existing PubSub subscriber callback. Do not put the change in an unrelated module just because that module can broadcast messages.
        - Do not put application business logic inside modules that `use Phoenix.Presence`; those modules should remain Presence boundaries unless snippets clearly show custom behavior already belongs there.
        - Do not suggest changing a module's role unless the provided snippets show that module already owns that responsibility.
        - For Phoenix Presence join notifications, prefer existing PubSub subscribers and existing `%{event: "presence_diff"}` handlers shown in snippets.
        - Do not override framework/library callback wrappers such as `Phoenix.Presence.track/4`; prefer existing application event boundaries such as LiveView events, PubSub subscriptions, or existing GenServer callbacks shown in snippets.
        - Do not suggest adding a sibling OTP application module, such as `SomeApp` or `SomeApp.Application`, as a child in another application's supervisor unless snippets show a valid child spec and the user is asking for that supervision change.
        - Do not call callback functions such as `handle_info/2` directly from LiveViews, channels, or other modules. Use public APIs, `GenServer.call/2`, `GenServer.cast/2`, `send/2`, or PubSub messages according to the boundaries shown in snippets.
        - Never regenerate or copy an entire existing module from snippets.
        - Do not include unchanged existing functions in code blocks.
        - Do not start a code block with `defmodule` unless the user explicitly asks to create a brand-new module. A response that wraps a change in the existing module is invalid.
        - For large modules, return a focused explanation plus a minimal diff or only the exact new/changed functions.
        - If more than three functions would change, summarize the plan first and ask which file/function to patch next instead of dumping a long module.
        - Never use placeholder comments like `# ... existing code ...`, `# ...`, `Other functions...`, or `Your existing code...`.
        - If snippets show a broken or partial attempt, call that out and propose the smallest concrete fix.
        - Prefer naming exact files and callbacks to change over presenting generic setup steps.
        - Before finalizing, quality-check the answer: every "existing evidence" bullet must cite a visible snippet, every new function must have a visible caller or call-site change, and every code block must be directly pasteable into the named target without module wrappers or placeholders.

        Use this response shape for implementation requests:

        Target:
        <file path and function/callback to change>

        Existing evidence:
        <one to three bullets naming the snippets that prove this is the right boundary>

        Change:
        <minimal diff or exact new/changed functions only; if the required producer/subscriber evidence is missing, write "No patch from provided context" and name the missing file or event boundary instead>
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

  defp final_answer_contract_messages(question) do
    if implementation_question?(question) and not refactor_question?(question) do
      [
        Prompts.system_message(final_answer_contract(question))
      ]
    else
      []
    end
  end

  defp final_answer_contract(question) do
    if guidance_request?(question) and not patch_request?(question) do
      """
      Final answer rules for this implementation guidance request:
      - Keep the entire answer under 500 words.
      - Do not include any code block.
      - Do not output a complete module or complete file.
      - Do not invent config, routes, supervision, PubSub topics, events, modules, or APIs that are not visible in snippets.
      - Give file/function direction only: name the target file, the exact visible function/callback to inspect or change, and the missing producer/consumer side if evidence is incomplete.
      - For PubSub wiring, cite the visible producer and visible consumer. If either is missing, say "No patch from provided context" and name the missing side.
      - Do not say "here is a possible refactoring"; this is guidance, not a patch.
      """
    else
      """
      Final answer rules for this implementation request:
      - Keep the entire answer under 900 words.
      - Do not output a complete module or complete file.
      - Do not start any code block with `defmodule`.
      - Do not include module docs, unchanged aliases, unchanged callbacks, or unchanged helper functions.
      - Do not include placeholder comments such as `# ...`, `# existing code`, or `# unchanged`.
      - If showing code, show a unified diff or only the exact changed function/callback, capped at 60 lines total.
      - Do not invent a new event such as `"new_player_join"` unless a visible snippet already broadcasts or consumes that exact event.
      - Do not add a new public helper unless the same answer also shows the visible caller/call-site change.
      - For PubSub wiring, cite the visible producer and visible consumer. If either is missing, answer with "No patch from provided context" and name the missing side.
      """
    end
  end

  defp refactor_question?(question) when is_binary(question) do
    normalized = String.downcase(question)
    Enum.any?(@refactor_keywords, &String.contains?(normalized, &1))
  end

  defp refactor_question?(_question), do: false

  defp review_question?(question) when is_binary(question) do
    normalized = String.downcase(question)
    Regex.match?(~r/\b(review|check|audit|look over)\b/, normalized)
  end

  defp review_question?(_question), do: false

  defp guidance_request?(question) when is_binary(question) do
    normalized = String.downcase(question)

    Regex.match?(
      ~r/\b(how can|how do|where should|what should|what file|which file)\b/,
      normalized
    )
  end

  defp guidance_request?(_question), do: false

  defp patch_request?(question) when is_binary(question) do
    normalized = String.downcase(question)

    Regex.match?(
      ~r/\b(show code|write code|give code|patch|diff|implement it|make the change|exact code|code block|edit|modify|add the function|create the function)\b/,
      normalized
    )
  end

  defp patch_request?(_question), do: false

  defp implementation_question?(question) when is_binary(question) do
    normalized = String.downcase(question)

    Regex.match?(
      ~r/\b(how can|how do|implement|add|include|included|wire|connect|notify|broadcast|broadcasting|when|on new|on join|joins?)\b/,
      normalized
    )
  end

  defp implementation_question?(_question), do: false

  defp maybe_current_file_message(nil), do: []

  defp maybe_current_file_message(current_file) when is_binary(current_file) do
    [
      Prompts.system_message("""
      Current file selected in the editor:
      #{current_file}
      """)
    ]
  end

  defp maybe_related_file_specs_message(_current_file, []), do: []

  defp maybe_related_file_specs_message(current_file, related_file_specs) do
    content =
      """
      Opened file and attached related objects:
      Opened file: #{current_file || "[none]"}

      Related objects included in this prompt:
      #{Enum.map_join(related_file_specs, "\n", &format_related_file_spec/1)}
      """

    [Prompts.system_message(content)]
  end

  defp format_related_file_spec(spec) do
    functions =
      spec.functions
      |> Enum.take(8)
      |> Enum.map_join(", ", &format_related_function/1)

    functions = if functions == "", do: "none extracted", else: functions

    "- #{spec.path} | relationship: #{spec.relationship} | public API: #{functions}"
  end

  defp format_related_function(function) do
    name = Map.get(function, :name, Map.get(function, "name", "[unknown]"))
    spec = Map.get(function, :spec, Map.get(function, "spec"))
    head = Map.get(function, :head, Map.get(function, "head", name))
    start_line = Map.get(function, :start_line, Map.get(function, "start_line"))
    end_line = Map.get(function, :end_line, Map.get(function, "end_line"))
    contract = if is_binary(spec) and spec != "", do: spec, else: head

    "#{name} (#{contract}, lines #{format_lines(start_line, end_line)})"
  end

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
    SOURCE: #{context_source_label(ref)}
    FILE: #{ref.path || "[unknown]"}
    LINES: #{format_lines(ref.start_line, ref.end_line)}
    ```#{language_for_ref(ref)}
    #{content}
    ```
    """
  end

  defp context_source_label(%ContextRef{metadata: %{source: :open_file}}) do
    "open file supporting context"
  end

  defp context_source_label(%ContextRef{type: :current_file}), do: "current selected file"
  defp context_source_label(_ref), do: "retrieved project context"

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

  defp normalize_related_file_specs(related_file_specs) when is_list(related_file_specs) do
    related_file_specs
    |> Enum.filter(&is_map/1)
    |> Enum.flat_map(fn spec ->
      case Map.get(spec, :path, Map.get(spec, "path")) do
        path when is_binary(path) ->
          [
            %{
              path: path,
              relationship:
                to_string(Map.get(spec, :relationship, Map.get(spec, "relationship", "related"))),
              included?: Map.get(spec, :included?, Map.get(spec, "included?", true)),
              functions:
                normalize_related_functions(
                  Map.get(spec, :functions, Map.get(spec, "functions", []))
                )
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.path)
  end

  defp normalize_related_file_specs(_related_file_specs), do: []

  defp normalize_related_functions(functions) when is_list(functions) do
    functions
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn function ->
      %{
        name: Map.get(function, :name, Map.get(function, "name", "[unknown]")),
        spec: Map.get(function, :spec, Map.get(function, "spec")),
        head: Map.get(function, :head, Map.get(function, "head", "[unknown]")),
        start_line: Map.get(function, :start_line, Map.get(function, "start_line")),
        end_line: Map.get(function, :end_line, Map.get(function, "end_line"))
      }
    end)
  end

  defp normalize_related_functions(_functions), do: []

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
