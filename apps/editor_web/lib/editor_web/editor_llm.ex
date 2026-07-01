defmodule EditorWeb.EditorLlm do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  @llm_open_file_max_chars 12_000
  @llm_open_file_total_max_chars 48_000

  @edit_intent_words [
    "apply",
    "change",
    "clean up",
    "deal with",
    "delete",
    "deduplicate",
    "fix",
    "handle",
    "implement",
    "move",
    "refactor",
    "remove",
    "rename",
    "replace",
    "rewrite",
    "simplify",
    "update"
  ]

  @recommendation_intent_words [
    "recommendation",
    "recommendations",
    "item",
    "items"
  ]

  @type response_segment :: {:text, String.t()} | {:code, String.t(), String.t()}

  @type modal_message :: %{
          id: String.t(),
          role: String.t(),
          content: String.t(),
          pending?: boolean()
        }

  @type related_file_function :: %{
          name: String.t(),
          kind: String.t(),
          spec: String.t() | nil,
          head: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }

  @type related_file_contract :: %{
          name: String.t(),
          spec: String.t() | nil,
          head: String.t(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }

  @request_assign_keys [
    :cwd,
    :selected_file,
    :related_files,
    :related_file_context_overrides,
    :llm_conversation_id,
    :cached_open_files,
    :open_tabs
  ]

  @spec assign_defaults(term(), String.t()) :: term()
  def assign_defaults(socket, cwd) do
    socket
    |> assign(:llm_modal_open?, false)
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_messages, [])
    |> assign(:llm_context, nil)
    |> assign(:llm_error, nil)
    |> assign(:llm_conversation_id, new_conversation_id(cwd))
    |> assign(:llm_pending_question, nil)
    |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))
  end

  @spec reset_conversation(term(), String.t()) :: term()
  def reset_conversation(socket, cwd) do
    socket
    |> assign(:llm_conversation_id, new_conversation_id(cwd))
    |> assign(:llm_messages, [])
    |> assign(:llm_pending_question, nil)
  end

  @spec restore_modal_state(term(), boolean()) :: term()
  def restore_modal_state(socket, modal_open?) do
    assign(socket, :llm_modal_open?, modal_open?)
  end

  @spec apply_updates(term(), map() | keyword()) :: term()
  def apply_updates(socket, updates) when is_map(updates) do
    Enum.reduce(updates, socket, fn {key, value}, acc -> assign(acc, key, value) end)
  end

  def apply_updates(socket, updates) when is_list(updates) do
    Enum.reduce(updates, socket, fn {key, value}, acc -> assign(acc, key, value) end)
  end

  @doc false
  @spec request_assigns(map()) :: map()
  def request_assigns(assigns) when is_map(assigns) do
    Map.take(assigns, @request_assign_keys)
  end

  @spec prepare_request(map(), String.t() | nil) ::
          {:noop, :loading} | {:error, keyword()} | {:ok, %{socket_updates: keyword()}}
  def prepare_request(assigns, question) do
    trimmed_question = String.trim(question || "")

    cond do
      assigns.llm_loading? ->
        {:noop, :loading}

      trimmed_question == "" ->
        {:error,
         [
           llm_error: "Enter a question.",
           llm_response: nil,
           llm_context: nil,
           llm_form: to_form(%{"question" => question}, as: :llm)
         ]}

      true ->
        {:ok,
         %{
           socket_updates: [
             llm_loading?: true,
             llm_error: nil,
             llm_response: nil,
             llm_context: preview_context(assigns, trimmed_question),
             llm_form: to_form(%{"question" => question}, as: :llm),
             llm_pending_question: trimmed_question
           ]
         }}
    end
  end

  @spec agent_chat(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def agent_chat(assigns, question) when is_map(assigns) and is_binary(question) do
    with {:ok, context} <- request_context(assigns, question),
         prepared_question = prepare_agent_question(assigns, question),
         {:ok, response} <-
           Llm.agent_chat(
             prepared_question,
             cwd: assigns.cwd,
             context: context,
             buffer_context: editor_buffer_context()
           ) do
      {:ok,
       %{
         response: response,
         llm_context: preview_context(context, assigns, question)
       }}
    end
  end

  @spec tool_agent_chat(map(), String.t()) ::
          {:ok, %{response: String.t() | map(), llm_context: map() | nil}} | {:error, term()}
  def tool_agent_chat(assigns, question) when is_map(assigns) and is_binary(question) do
    cwd = Map.fetch!(assigns, :cwd)
    selected_file = Map.get(assigns, :selected_file)

    system_message = """
    You are a local editor assistant operating inside one workspace.

    Tool-use rules:
    - Use only the provided read-only editor tools.
    - The workspace root is authoritative. Never operate outside it.
    - If the user does not specify a path, search from ".".
    - Do not use editor_read_file on a directory.
    - Use editor_search_text to find candidate files.
    - Use editor_list_files to discover project structure.
    - Use editor_read_file only on a specific file path returned by search/list results or on the selected file.
    - If the user asks to explain an implementation, search first, then read the most relevant file, then answer.
    - Do not claim that something does not exist until you have searched from "." or from the user-specified path.
    - Do not say "I will now search" after tool use. Either use a tool or answer from the results.
    - Prefer concise answers with file paths, line numbers from search results, and clear reasoning.
    - If the user asks to search but does not specify a path, use editor_search_workspace first.
    - Use editor_search_text only when the user explicitly provides a directory or file path.
    - If the user asks to explain an implementation, search first, then read the most relevant file, then answer.
    - Do not conclude something does not exist after searching only a narrow guessed path.
    - Do not use editor_read_file on a directory.
    """

    user_message = """
    Workspace root:
    #{cwd}

    Selected file:
    #{selected_file || "(none)"}

    User question:
    #{question}
    """

    messages = [
      %{role: "system", content: system_message},
      %{role: "user", content: user_message}
    ]

    with {:ok, response} <-
           Llm.tool_chat(messages,
             max_tool_rounds: 6,
             max_tokens: 1_024
           ) do
      {:ok,
       %{
         response: response,
         llm_context: %{
           mode: :native_tool_loop,
           cwd: cwd,
           selected_file: selected_file
         }
       }}
    end
  end

  @spec handle_success(term(), String.t() | nil) :: term()
  def handle_success(socket, response) do
    handle_success(socket, response, socket.assigns.llm_context)
  end

  @spec handle_success(term(), String.t() | nil, term()) :: term()
  def handle_success(socket, response, llm_context) do
    pending_question = socket.assigns.llm_pending_question || ""

    snapshot =
      if pending_question != "" do
        Llm.Conversation.record_turn(
          socket.assigns.llm_conversation_id,
          pending_question,
          response,
          socket.assigns.cwd
          |> conversation_attrs(socket.assigns.selected_file)
          |> Map.put(:store_assistant?, true)
        )
      end

    messages =
      case snapshot do
        %{messages: messages} when is_list(messages) -> messages
        _ -> Map.get(socket.assigns, :llm_messages, [])
      end

    socket
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, response)
    |> assign(:llm_messages, messages)
    |> assign(:llm_context, llm_context)
    |> assign(:llm_pending_question, nil)
    |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))
    |> assign(:llm_error, nil)
  end

  @spec handle_failure(term(), :request_failed | :task_crashed, term()) :: term()
  def handle_failure(socket, :request_failed, reason) do
    socket
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_context, nil)
    |> assign(:llm_pending_question, nil)
    |> assign(:llm_error, "LLM request failed: #{inspect(reason)}")
  end

  def handle_failure(socket, :task_crashed, reason) do
    socket
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_context, nil)
    |> assign(:llm_pending_question, nil)
    |> assign(:llm_error, "LLM task crashed: #{inspect(reason)}")
  end

  @spec target_label(String.t(), String.t() | nil) :: String.t()
  def target_label(cwd, nil), do: "Folder: #{cwd}"
  def target_label(_cwd, selected_file), do: "File: #{selected_file}"

  @spec history_status_label(map()) :: String.t() | nil
  def history_status_label(%{llm_conversation_id: conversation_id})
      when is_binary(conversation_id) do
    message_count = conversation_message_count(conversation_id)

    if message_count > 0 do
      "History retained • #{message_count} #{pluralize(message_count, "message")}"
    else
      "History retained"
    end
  end

  def history_status_label(_assigns), do: nil

  @spec modal_messages(map()) :: [modal_message()]
  def modal_messages(assigns) when is_map(assigns) do
    assigns
    |> assigned_modal_messages()
    |> maybe_append_pending_message(assigns)
  end

  @spec prompt_stats_label(term()) :: String.t() | nil
  def prompt_stats_label(%{"prompt_stats" => stats} = context) when is_map(stats) do
    estimated_tokens = map_value(stats, :estimated_tokens, 0)
    message_count = map_value(stats, :message_count, 0)

    parts =
      [
        "~#{estimated_tokens} #{pluralize(estimated_tokens, "token")}",
        "#{message_count} #{pluralize(message_count, "message")}"
      ] ++ file_count_stats_parts(context)

    "Prompt: " <> Enum.join(parts, " | ")
  end

  def prompt_stats_label(_context), do: nil

  @spec response_segments(String.t() | nil) :: [response_segment()]
  def response_segments(nil), do: []

  def response_segments(response) when is_binary(response) do
    response
    |> String.split("\n", trim: false)
    |> parse_response([], [], nil)
    |> Enum.reverse()
    |> Enum.reject(fn
      {:text, text} -> String.trim(text) == ""
      {:code, _language, code} -> String.trim(code) == ""
    end)
  end

  def response_segments(_response), do: []

  @spec related_files(map()) :: [String.t()]
  def related_files(%{
        selected_file: selected_file,
        related_files: related_files,
        related_file_context_overrides: overrides
      })
      when is_binary(selected_file) and is_list(related_files) and is_map(overrides) do
    Enum.filter(related_files, &related_file_included?(selected_file, &1, overrides))
  end

  def related_files(%{related_files: related_files}) when is_list(related_files),
    do: related_files

  def related_files(_assigns), do: []

  @spec related_file_specs(map()) :: [map()]
  def related_file_specs(%{
        selected_file: selected_file,
        related_files: related_files,
        related_file_context_overrides: overrides
      })
      when is_binary(selected_file) and is_list(related_files) and is_map(overrides) do
    related_files
    |> Enum.filter(&related_file_included?(selected_file, &1, overrides))
    |> Enum.map(fn path ->
      %{
        path: path,
        relationship: related_file_reason(selected_file, path),
        included?: true,
        functions: related_file_public_contracts(selected_file, path)
      }
    end)
  end

  def related_file_specs(_assigns), do: []

  @spec related_file_included?(map(), String.t()) :: boolean()
  def related_file_included?(assigns, path) when is_map(assigns) and is_binary(path) do
    related_file_included?(
      Map.get(assigns, :selected_file),
      path,
      Map.get(assigns, :related_file_context_overrides, %{})
    )
  end

  @spec related_file_included?(String.t() | nil, String.t(), map()) :: boolean()
  def related_file_included?(selected_path, path, overrides)
      when is_binary(path) and is_map(overrides) do
    case Map.fetch(overrides, path) do
      {:ok, included?} -> included?
      :error -> strong_related_file?(selected_path, path)
    end
  end

  def related_file_included?(_selected_path, _path, _overrides), do: false

  @spec strong_related_file?(String.t() | nil, String.t()) :: boolean()
  def strong_related_file?(selected_path, path) do
    related_file_reason(selected_path, path) in [
      "uses",
      "used by",
      "uses/used by",
      "test/template"
    ]
  end

  @spec related_file_reason(String.t() | nil, String.t()) :: String.t()
  def related_file_reason(nil, _path), do: "related"

  def related_file_reason(selected_path, path)
      when is_binary(selected_path) and is_binary(path) do
    selected_analysis = file_analysis(selected_path)
    related_analysis = file_analysis(path)

    selected_uses_related? =
      Enum.any?(related_analysis.defined_modules, &(&1 in selected_analysis.referenced_modules))

    related_uses_selected? =
      Enum.any?(selected_analysis.defined_modules, &(&1 in related_analysis.referenced_modules))

    cond do
      selected_uses_related? and related_uses_selected? -> "uses/used by"
      selected_uses_related? -> "uses"
      related_uses_selected? -> "used by"
      convention_related_file?(selected_path, path) -> "test/template"
      true -> "related"
    end
  end

  def related_file_reason(_selected_path, _path), do: "related"

  @spec related_file_functions(String.t() | nil, String.t()) :: [related_file_function()]
  def related_file_functions(nil, _path), do: []

  def related_file_functions(selected_path, path)
      when is_binary(selected_path) and is_binary(path) do
    called_names = called_related_function_names(selected_path, path)

    path
    |> Llm.ContextBuilder.extract_function()
    |> Enum.map(fn function ->
      %{
        name: Map.get(function, :name, "[unknown]"),
        kind: Map.get(function, :kind, "def"),
        spec: Map.get(function, :spec),
        head: Map.get(function, :head, "[unknown]"),
        start_line: Map.get(function, :start_line, 1),
        end_line: Map.get(function, :end_line, 1)
      }
    end)
    |> Enum.reject(&(&1.name == "[unknown]"))
    |> Enum.filter(&MapSet.member?(called_names, &1.name))
    |> Enum.uniq_by(&{&1.name, &1.start_line, &1.end_line})
    |> Enum.take(8)
  end

  @spec related_file_public_contracts(String.t() | nil, String.t()) :: [related_file_contract()]
  def related_file_public_contracts(nil, _path), do: []

  def related_file_public_contracts(selected_path, path) do
    related_file_functions(selected_path, path)
    |> Enum.filter(&public_related_function?/1)
    |> Enum.map(fn function ->
      %{
        name: function.name,
        spec: function.spec,
        head: function.head,
        start_line: function.start_line,
        end_line: function.end_line
      }
    end)
  end

  defp prepare_agent_question(assigns, question) do
    question = String.trim(question || "")

    if edit_intent?(question) do
      edit_agent_question(assigns, question)
    else
      question
    end
  end

  defp edit_intent?(question) when is_binary(question) do
    text = String.downcase(question)

    contains_any?(text, @edit_intent_words) or
      recommendation_edit_intent?(text)
  end

  defp edit_intent?(_question), do: false

  defp recommendation_edit_intent?(text) when is_binary(text) do
    contains_any?(text, @recommendation_intent_words) and
      String.contains?(text, ["1", "2", "3", "one", "two", "three", "through", "to", "-"])
  end

  defp contains_any?(text, words) when is_binary(text) and is_list(words) do
    Enum.any?(words, &String.contains?(text, &1))
  end

  defp edit_agent_question(assigns, question) do
    cwd = Map.get(assigns, :cwd)
    selected_file = Map.get(assigns, :selected_file)
    selected_file_label = selected_file_label(selected_file, cwd)

    """
    You are acting as this editor's code-change agent.

    Workspace root:
    #{cwd}

    Selected file:
    #{selected_file_label}

    User request:
    #{question}

    Output contract:
    - Return only a unified diff inside a fenced diff code block.
    - Do not write a tutorial.
    - Do not repeat generic recommendations.
    - Do not say "Certainly", "I can help", or similar filler.
    - Do not claim changes unless the diff contains the change.
    - Preserve public APIs unless the user explicitly asks otherwise.
    - Keep the patch minimal, focused, and compilable.
    - Patch the selected file unless the user clearly names another file.
    - If the selected file is missing or the request needs another file, return exactly: NEED_MORE_CONTEXT: reason.
    - If no code change is needed, return exactly: NO_CHANGE_NEEDED: reason.
    """
  end

  defp selected_file_label(path, cwd) when is_binary(path) and is_binary(cwd) do
    expanded_cwd = Path.expand(cwd)

    expanded_path =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, expanded_cwd)
      end

    relative = Path.relative_to(expanded_path, expanded_cwd)

    if relative == expanded_path do
      path
    else
      relative
    end
  rescue
    _ -> path
  end

  defp selected_file_label(path, _cwd) when is_binary(path), do: path
  defp selected_file_label(_path, _cwd), do: "[none]"

  defp new_conversation_id(cwd) do
    conversation_id = Llm.Conversation.new_id(cwd)
    Llm.Conversation.ensure(conversation_id, project_id: cwd)
    conversation_id
  end

  defp conversation_attrs(cwd, selected_file) do
    %{
      project_id: cwd,
      current_file: selected_file
    }
  end

  defp request_context(assigns, question) do
    trimmed_question = String.trim(question || "")
    conversation_id = Map.get(assigns, :llm_conversation_id)

    Llm.build_context(
      assigns.cwd,
      assigns.selected_file,
      trimmed_question,
      related_files: related_files(assigns),
      related_file_specs: related_file_specs(assigns),
      open_files: open_file_paths_for_agent(assigns),
      token_budget: 16_384,
      conversation_id: conversation_id,
      recent_messages: recent_messages(conversation_id),
      conversation_summary: conversation_summary(conversation_id)
    )
  end

  defp preview_context(assigns, question) when is_map(assigns) and is_binary(question) do
    open_files = open_file_paths_for_agent(assigns)
    related = related_files(assigns)

    %{
      "mode" => if(is_binary(assigns.selected_file), do: "file", else: "folder"),
      "path" => assigns.selected_file || assigns.cwd,
      "question" => question,
      "file_count" => related_file_count(assigns.selected_file, related),
      "open_file_count" => length(open_files),
      "conversation_id" => assigns.llm_conversation_id,
      "recent_message_count" => length(recent_messages(assigns.llm_conversation_id)),
      "prompt_stats" => %{
        estimated_tokens: div(String.length(question), 4),
        message_count: 1
      }
    }
  end

  defp preview_context(%{pack: pack} = context, assigns, question) when is_binary(question) do
    metadata = Map.get(pack, :metadata, %{})

    %{
      "mode" => context_mode_label(Map.get(context, :mode)),
      "path" => Map.get(context, :primary_path) || assigns.cwd,
      "question" => question,
      "file_count" => length(Map.get(context, :files, [])),
      "open_file_count" => length(open_file_paths_for_agent(assigns)),
      "conversation_id" => Map.get(assigns, :llm_conversation_id),
      "recent_message_count" => map_value(metadata, :recent_message_count, 0),
      "prompt_stats" => %{
        estimated_tokens: Map.get(pack, :estimated_tokens, 0),
        message_count: length(Map.get(context, :messages, []))
      }
    }
  end

  defp context_mode_label(:file), do: "file"
  defp context_mode_label(:folder), do: "folder"
  defp context_mode_label(other) when is_atom(other), do: Atom.to_string(other)
  defp context_mode_label(other) when is_binary(other), do: other
  defp context_mode_label(_other), do: "unknown"

  defp related_file_count(nil, related_files), do: length(related_files)
  defp related_file_count(_selected_file, related_files), do: length(related_files) + 1

  defp recent_messages(nil), do: []

  defp recent_messages(conversation_id) when is_binary(conversation_id) do
    Llm.Conversation.recent_messages(conversation_id)
  end

  defp conversation_summary(nil), do: nil

  defp conversation_summary(conversation_id) when is_binary(conversation_id) do
    Llm.Conversation.summary(conversation_id)
  end

  defp cached_open_files do
    Editor.OpenFileCache.list_files()
    |> Enum.sort_by(fn opened_file ->
      {if(opened_file.in_focus?, do: 0, else: 1), opened_file.opened_at}
    end)
  end

  defp cached_open_file_paths(assigns) do
    assigns
    |> Map.get(:cached_open_files, [])
    |> Enum.map(fn
      %{path: path} when is_binary(path) -> path
      %{"path" => path} when is_binary(path) -> path
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp open_file_paths_for_context([], open_tabs) do
    open_tabs
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp open_file_paths_for_context(cached_open_file_paths, _open_tabs) do
    cached_open_file_paths
  end

  defp open_file_paths_for_agent(assigns) do
    cached_paths = cached_open_file_paths(assigns)
    open_tabs = Map.get(assigns, :open_tabs, [])

    open_file_paths_for_context(cached_paths, open_tabs)
  end

  defp editor_buffer_context do
    case cached_open_files() do
      [] -> nil
      opened_files -> cached_open_files_prompt(opened_files)
    end
  end

  defp cached_open_files_prompt(cached_open_files) do
    files =
      cached_open_files
      |> open_files_for_prompt()
      |> Enum.map_join(
        "\n\n",
        &format_cached_open_file/1
      )

    """
    Open editor buffers:
    These are the current cached editor buffers. Prefer these exact contents over on-disk project-memory snippets when they overlap, because they may include unsaved edits.

    #{files}
    """
  end

  defp open_files_for_prompt(cached_open_files) do
    cached_open_files
    |> Enum.reduce_while({[], 0}, fn opened_file, {files, total_chars} ->
      remaining_chars = @llm_open_file_total_max_chars - total_chars

      if remaining_chars <= 0 do
        {:halt, {files, total_chars}}
      else
        max_chars = min(@llm_open_file_max_chars, remaining_chars)
        content = Llm.Prompts.truncate_content(opened_file.content, max_chars)
        prompt_file = %{opened_file | content: content}

        {:cont, {[prompt_file | files], total_chars + String.length(content)}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp format_cached_open_file(opened_file) do
    """
    FILE: #{opened_file.path}
    IN_FOCUS: #{opened_file.in_focus?}
    BYTES: #{opened_file.byte_size}
    OPENED_AT: #{opened_file.opened_at}
    ```#{language_for_path(opened_file.path)}
    #{opened_file.content}
    ```
    """
  end

  defp language_for_path(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "heex"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "tsx"
      ".json" -> "json"
      ".md" -> "markdown"
      _ -> ""
    end
  end

  defp file_analysis(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path) do
      Llm.ContextBuilder.analyze_file(content)
    else
      _ -> %{defined_modules: [], referenced_modules: [], public_functions: []}
    end
  end

  defp convention_related_file?(selected_path, path) do
    selected_basename = Path.basename(selected_path, Path.extname(selected_path))
    related_basename = Path.basename(path, Path.extname(path))

    related_basename in [
      selected_basename,
      "#{selected_basename}_test"
    ] or String.ends_with?(path, "/#{selected_basename}_test.exs")
  end

  defp called_related_function_names(selected_path, related_path) do
    with true <- File.regular?(selected_path),
         {:ok, selected_content} <- File.read(selected_path) do
      related_modules =
        related_path
        |> file_analysis()
        |> Map.get(:defined_modules, [])
        |> MapSet.new()

      selected_content
      |> remote_calls_in_content()
      |> Enum.filter(fn %{module: module_name} ->
        MapSet.member?(related_modules, module_name)
      end)
      |> Enum.map(& &1.function)
      |> MapSet.new()
    else
      _ -> MapSet.new()
    end
  end

  defp remote_calls_in_content(content) when is_binary(content) do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        alias_map = alias_map_from_ast(ast)

        {_ast, calls} =
          Macro.prewalk(ast, [], fn
            {{:., _, [module_ast, function_name]}, _, _args} = node, acc
            when is_atom(function_name) ->
              case resolve_called_module(module_ast, alias_map) do
                nil ->
                  {node, acc}

                module_name ->
                  {node, [%{module: module_name, function: Atom.to_string(function_name)} | acc]}
              end

            node, acc ->
              {node, acc}
          end)

        calls
        |> Enum.uniq()
        |> Enum.reverse()

      {:error, _reason} ->
        []
    end
  end

  defp alias_map_from_ast(ast) do
    {_ast, alias_map} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          module_name = Enum.join(parts, ".")
          short_name = parts |> List.last() |> Atom.to_string()
          {node, Map.put(acc, short_name, module_name)}

        {:alias, _, [{:__aliases__, _, parts}, [as: {:__aliases__, _, as_parts}]]} = node, acc ->
          module_name = Enum.join(parts, ".")
          alias_name = as_parts |> List.last() |> Atom.to_string()
          {node, Map.put(acc, alias_name, module_name)}

        node, acc ->
          {node, acc}
      end)

    alias_map
  end

  defp resolve_called_module({:__aliases__, _, parts}, alias_map) when is_list(parts) do
    case parts do
      [part] -> Map.get(alias_map, Atom.to_string(part))
      _ -> Enum.join(parts, ".")
    end
  end

  defp resolve_called_module(_other, _alias_map), do: nil

  defp public_related_function?(%{kind: kind}), do: kind in ["def", "defmacro", "defdelegate"]

  defp assigned_modal_messages(%{llm_messages: messages}) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, index} ->
      %{
        id: message_dom_id(message, index),
        role: Map.get(message, :role, "user"),
        content: Map.get(message, :content, ""),
        pending?: false
      }
    end)
  end

  defp assigned_modal_messages(assigns), do: stored_modal_messages(assigns)

  defp stored_modal_messages(%{llm_conversation_id: conversation_id})
       when is_binary(conversation_id) do
    case Process.whereis(Llm.Conversation) do
      nil ->
        []

      _pid ->
        conversation_id
        |> Llm.Conversation.recent_messages(48, include_assistant?: true)
        |> Enum.with_index()
        |> Enum.map(fn {message, index} ->
          %{
            id: message_dom_id(message, index),
            role: Map.get(message, :role, "user"),
            content: Map.get(message, :content, ""),
            pending?: false
          }
        end)
    end
  end

  defp stored_modal_messages(_assigns), do: []

  defp maybe_append_pending_message(messages, %{
         llm_pending_question: question,
         llm_loading?: true
       })
       when is_binary(question) do
    question = String.trim(question)

    if question == "" do
      messages
    else
      messages ++
        [
          %{
            id: "pending-user-message",
            role: "user",
            content: question,
            pending?: true
          },
          %{
            id: "pending-assistant-message",
            role: "assistant",
            content: "Thinking...",
            pending?: true
          }
        ]
    end
  end

  defp maybe_append_pending_message(messages, _assigns), do: messages

  defp message_dom_id(message, index) do
    role = Map.get(message, :role, "")
    content = Map.get(message, :content, "")

    :crypto.hash(:sha256, "#{index}:#{role}:#{content}")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  defp parse_response([], current_lines, segments, nil) do
    text = Enum.reverse(current_lines) |> Enum.join("\n")

    if text == "" do
      segments
    else
      [{:text, text} | segments]
    end
  end

  defp parse_response([], current_lines, segments, language) do
    code = Enum.reverse(current_lines) |> Enum.join("\n")
    [{:code, language, code} | segments]
  end

  defp parse_response([line | rest], current_lines, segments, nil) do
    case Regex.run(~r/^```([\w+-]*)\s*$/, line) do
      [_, language] ->
        text = Enum.reverse(current_lines) |> Enum.join("\n")

        new_segments =
          if text == "" do
            segments
          else
            [{:text, text} | segments]
          end

        parse_response(rest, [], new_segments, language)

      nil ->
        parse_response(rest, [line | current_lines], segments, nil)
    end
  end

  defp parse_response([line | rest], current_lines, segments, language) do
    if String.trim(line) == "```" do
      code = Enum.reverse(current_lines) |> Enum.join("\n")
      parse_response(rest, [], [{:code, language, code} | segments], nil)
    else
      parse_response(rest, [line | current_lines], segments, language)
    end
  end

  defp file_count_stats_parts(context) do
    case Map.get(context, "file_count") do
      count when is_integer(count) ->
        ["#{count} #{pluralize(count, "file")}"]

      _ ->
        []
    end
  end

  defp conversation_message_count(conversation_id) do
    case Process.whereis(Llm.Conversation) do
      nil ->
        0

      _pid ->
        conversation_id
        |> Llm.Conversation.recent_messages()
        |> length()
    end
  end

  defp map_value(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end

  defp map_value(_map, _key, default), do: default

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"
end
