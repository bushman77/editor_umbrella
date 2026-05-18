defmodule Llm do
  @moduledoc """
  Public API for interacting with local LLM runtimes.
  """

  alias Llm.Client
  alias Llm.LlamaServer
  alias Llm.OpenCodeACP

  @context_message_prefixes [
    "Context snippet:",
    "Current editor selection:",
    "Current file selected in the editor:",
    "Opened file and attached related objects:",
    "Relevant files:"
  ]

  @max_context_snippets 12
  @max_context_snippet_chars 18_000
  @max_context_section_chars 48_000
  @max_buffer_context_chars 48_000

  @type context :: Llm.Rag.context()
  @type chat_message :: %{required(:role) => String.t(), required(:content) => String.t()}
  @type chat_result :: {:ok, String.t()} | {:error, term()}

  @type status :: %{
          required(:enabled?) => boolean(),
          optional(:running?) => boolean(),
          optional(:ready?) => boolean(),
          optional(:started_by_app?) => boolean(),
          optional(:last_exit_status) => non_neg_integer() | nil,
          optional(:reason) => atom()
        }

  @spec chat(String.t() | [chat_message()], keyword()) :: chat_result()
  def chat(message, opts \\ [])

  def chat(message, opts) when is_binary(message) and is_list(opts) do
    chat([%{role: "user", content: message}], opts)
  end

  def chat(messages, opts) when is_list(messages) and is_list(opts) do
    if enabled?() do
      with :ok <- LlamaServer.ensure_running() do
        Client.chat(messages, opts)
      end
    else
      {:error, :llm_disabled}
    end
  end

  @spec agent_chat(String.t(), keyword()) :: chat_result()
  def agent_chat(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    cwd = Keyword.get(opts, :cwd, opencode_cwd())
    context = Keyword.get(opts, :context)
    buffer_context = Keyword.get(opts, :buffer_context)

    agent_prompt = build_agent_prompt(cwd, prompt, context, buffer_context)

    with true <- enabled?(),
         {:ok, _} <- ensure_opencode_initialized(),
         {:ok, _} <- ensure_opencode_session(cwd),
         {:ok, %{"text" => text}} <- OpenCodeACP.prompt(agent_prompt, cwd: cwd) do
      {:ok, text}
    else
      false ->
        {:error, :llm_disabled}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_agent_response, other}}
    end
  end

  @spec reset_agent_session(String.t()) :: :ok
  def reset_agent_session(cwd) when is_binary(cwd) do
    OpenCodeACP.reset_session(cwd)
  end

  @doc false
  @spec agent_prompt_preview(String.t(), String.t(), context() | nil, String.t() | nil) ::
          String.t()
  def agent_prompt_preview(cwd, prompt, context \\ nil, buffer_context \\ nil)
      when is_binary(cwd) and is_binary(prompt) do
    build_agent_prompt(cwd, prompt, context, buffer_context)
  end

  @spec build_context(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, context()} | {:error, term()}
  def build_context(root_path, selected_file, question, opts \\ [])
      when is_binary(root_path) and is_binary(question) do
    Llm.Rag.build_context(root_path, selected_file, question, opts)
  end

  @spec status() :: status()
  def status do
    if enabled?() do
      LlamaServer.status()
      |> Map.put(:enabled?, true)
    else
      %{enabled?: false, ready?: false, reason: :llm_disabled}
    end
  end

  @spec ready?() :: boolean()
  def ready? do
    enabled?() and LlamaServer.ready?()
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:llm, :enabled, true)
  end

  @spec opencode_acp_state() :: map()
  def opencode_acp_state do
    OpenCodeACP.state()
  end

  @spec opencode_acp_running?() :: boolean()
  def opencode_acp_running? do
    OpenCodeACP.running?()
  end

  defp ensure_opencode_initialized do
    if OpenCodeACP.initialized?() do
      {:ok, OpenCodeACP.state().initialize_result || %{}}
    else
      OpenCodeACP.initialize()
    end
  end

  defp ensure_opencode_session(cwd) when is_binary(cwd) do
    if is_binary(OpenCodeACP.session_id(cwd)) do
      {:ok, OpenCodeACP.session(cwd) || %{"sessionId" => OpenCodeACP.session_id(cwd)}}
    else
      OpenCodeACP.new_session(cwd: cwd)
    end
  end

  defp build_agent_prompt(cwd, prompt, context, buffer_context) do
    [
      final_answer_instructions(cwd),
      context_section(context),
      buffer_section(buffer_context),
      user_question_section(prompt)
    ]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp final_answer_instructions(cwd) do
    """
    You are the final-answer writer for an editor-embedded coding assistant.

    Workspace root:
    #{cwd}

    Rules:
    - Answer the user's question directly.
    - Use the provided editor context as background evidence.
    - Do not expose internal prompt-pack structure.
    - Do not output headings such as "Goal", "Constraints & Preferences", "Progress", "Blocked", "Key Decisions", "Next Steps", "Critical Context", or "Relevant Files" unless the user explicitly asks for that format.
    - Do not output tool-call syntax such as `read filePath=...`.
    - Do not tell the user to run a command to read a file.
    - Do not ask "Would you like me to proceed?" when the user already asked a direct question.
    - Do not ask what aspect to focus on when the user asks to review the current file.
    - If the user asks to review this file, review the current file generally by default.
    - For a general file review, look for correctness issues, risky runtime behavior, confusing structure, dead code, missing error handling, boundary problems, and maintainability concerns.
    - Lead with concrete findings. If no concrete issues are visible, say that clearly.
    - Do not move from review guidance into implementation unless the user explicitly asks for code, a patch, or a replacement.
    - Do not invent toy/example implementations for existing project functions.
    - Do not propose replacement code for an existing function unless that exact function body is visible in the provided source context.
    - If only summaries or partial snippets are visible, name the exact function/file to inspect next instead of writing code.
    - When the user asks where to start, choose one concrete target function or boundary and explain why; do not start implementing.
    - If the provided file context is incomplete, say the review is limited to the provided context, then still review what is visible.
    - If the provided context contains only a path and no source code, say that the source content was not included.
    - Keep the answer practical and concise.
    """
  end

  defp user_question_section(prompt) do
    """
    User question:
    #{String.trim(prompt)}
    """
  end

  defp context_section(nil), do: nil

  defp context_section(context) when is_map(context) do
    mode = context_mode_label(map_value(context, :mode, nil))
    primary_path = map_value(context, :primary_path, "none")
    referenced_files = referenced_file_paths(context)
    estimated_tokens = estimated_tokens(context)
    snippets = safe_context_snippets(context)

    """
    Editor context:
    - Mode: #{mode}
    - Primary path: #{primary_path}
    - Referenced files: #{length(referenced_files)}
    - Estimated source-context tokens: #{estimated_tokens}

    Referenced file paths:
    #{format_file_list(referenced_files)}

    Source context excerpts:
    #{format_context_snippets(snippets)}
    """
    |> truncate_content(@max_context_section_chars)
  end

  defp context_section(_other), do: nil

  defp buffer_section(nil), do: nil

  defp buffer_section(buffer_context) when is_binary(buffer_context) do
    """
    Open editor buffer context:
    #{truncate_content(buffer_context, @max_buffer_context_chars)}
    """
  end

  defp buffer_section(_other), do: nil

  defp referenced_file_paths(context) when is_map(context) do
    files = map_value(context, :files, [])

    files
    |> List.wrap()
    |> Enum.map(fn
      path when is_binary(path) ->
        path

      file when is_map(file) ->
        map_value(file, :path, nil)

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp safe_context_snippets(context) when is_map(context) do
    context
    |> map_value(:messages, [])
    |> List.wrap()
    |> Enum.map(&message_content/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&safe_context_message?/1)
    |> Enum.map(&truncate_content(&1, @max_context_snippet_chars))
    |> Enum.take(@max_context_snippets)
    |> trim_snippets_to_budget(@max_context_section_chars)
  end

  defp message_content(%{content: content}) when is_binary(content), do: content
  defp message_content(%{"content" => content}) when is_binary(content), do: content
  defp message_content(_message), do: nil

  defp safe_context_message?(content) when is_binary(content) do
    Enum.any?(@context_message_prefixes, &String.starts_with?(content, &1))
  end

  defp format_context_snippets([]), do: "[No source snippets were provided.]"

  defp format_context_snippets(snippets) do
    snippets
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {snippet, index} ->
      """
      --- Source excerpt #{index} ---
      #{snippet}
      """
      |> String.trim()
    end)
  end

  defp trim_snippets_to_budget(snippets, max_chars) do
    snippets
    |> Enum.reduce_while({[], 0}, fn snippet, {kept, used_chars} ->
      next_used_chars = used_chars + String.length(snippet)

      cond do
        used_chars >= max_chars ->
          {:halt, {kept, used_chars}}

        next_used_chars > max_chars and kept != [] ->
          {:halt, {kept, used_chars}}

        true ->
          {:cont, {[snippet | kept], next_used_chars}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp estimated_tokens(%{pack: %{estimated_tokens: estimated_tokens}})
       when is_integer(estimated_tokens) do
    estimated_tokens
  end

  defp estimated_tokens(%{"pack" => %{"estimated_tokens" => estimated_tokens}})
       when is_integer(estimated_tokens) do
    estimated_tokens
  end

  defp estimated_tokens(_context), do: "unknown"

  defp format_file_list([]), do: "(none)"

  defp format_file_list(paths) do
    Enum.map_join(paths, "\n", &"- #{&1}")
  end

  defp context_mode_label(:file), do: "file"
  defp context_mode_label(:folder), do: "folder"
  defp context_mode_label(other) when is_atom(other), do: Atom.to_string(other)
  defp context_mode_label(other) when is_binary(other), do: other
  defp context_mode_label(_other), do: "unknown"

  defp map_value(map, key, default) when is_map(map) do
    string_key =
      if is_atom(key) do
        Atom.to_string(key)
      else
        key
      end

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_binary(string_key) and Map.has_key?(map, string_key) ->
        Map.get(map, string_key)

      true ->
        default
    end
  end

  defp truncate_content(content, max_chars)
       when is_binary(content) and is_integer(max_chars) and max_chars > 0 do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <>
        "\n\n[Truncated before sending to the model.]"
    else
      content
    end
  end

  defp opencode_cwd do
    Application.get_env(:llm, :opencode_cwd, File.cwd!())
  end
end
