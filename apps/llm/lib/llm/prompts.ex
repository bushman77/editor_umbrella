defmodule Llm.Prompts do
  @moduledoc """
  Prompt builders for the local LLM integration.

  This module returns chat-style message lists that can be passed directly to
  `Llm.chat/1` or `Llm.chat_raw/1`.
  """

  @editor_file_question_max_chars 6_000
  @editor_file_max_chars 12_000
  @editor_total_max_chars 48_000
  @editor_folder_file_list_limit 200
  @default_allowed_extensions [".ex", ".exs", ".heex", ".js", ".ts", ".tsx", ".json", ".md"]
  @skipped_directory_names [".git", ".elixir_ls", "_build", "deps", "node_modules"]
  @skipped_path_segments [
    ["priv", "static", "assets"]
  ]
  @refactor_keywords ["refactor", "rewrite", "clean up", "improve this file", "restructure"]

  @type role :: String.t()
  @type message :: %{role: role(), content: String.t()}
  @type messages :: [message()]
  @type prompt_file :: %{path: String.t(), content: String.t()}
  @type stats :: %{
          message_count: non_neg_integer(),
          total_chars: non_neg_integer(),
          estimated_tokens: non_neg_integer(),
          by_role: %{optional(role()) => role_stats()}
        }
  @type role_stats :: %{
          message_count: non_neg_integer(),
          chars: non_neg_integer(),
          estimated_tokens: non_neg_integer()
        }

  @spec editor_file_question(String.t(), String.t(), String.t()) :: messages()
  def editor_file_question(path, content, question)
      when is_binary(path) and is_binary(content) and is_binary(question) do
    max_chars =
      if refactor_question?(question) do
        @editor_file_max_chars
      else
        @editor_file_question_max_chars
      end

    file = %{path: path, content: truncate_content(content, max_chars)}

    editor_files_question([file], question, primary_path: path)
  end

  @spec editor_files_question([prompt_file()], String.t()) :: messages()
  def editor_files_question(files, question) when is_list(files) and is_binary(question) do
    editor_files_question(files, question, [])
  end

  @spec editor_files_question([prompt_file()], String.t(), keyword()) :: messages()
  def editor_files_question(files, question, opts) when is_list(files) and is_binary(question) do
    trimmed_question = String.trim(question)
    primary_path = Keyword.get(opts, :primary_path)
    mode = prompt_mode(trimmed_question, primary_path)

    prompt =
      case mode do
        :refactor ->
          refactor_prompt(files, trimmed_question, primary_path)

        :question ->
          question_prompt(files, trimmed_question, primary_path)
      end

    instructions =
      case mode do
        :refactor -> editor_refactor_instructions()
        :question -> editor_assistant_instructions()
      end

    [
      system_message(instructions),
      user_message(prompt)
    ]
  end

  @spec editor_folder_question(String.t(), String.t()) :: messages()
  def editor_folder_question(root_path, question)
      when is_binary(root_path) and is_binary(question) do
    files =
      root_path
      |> list_files_recursive()
      |> Enum.filter(&wanted_file?/1)
      |> Enum.take(@editor_folder_file_list_limit)
      |> Enum.map(&Path.relative_to(&1, root_path))

    prompt =
      """
      Folder root: #{Path.expand(root_path)}

      Project files:

      #{Enum.join(files, "\n")}

      Question:
      #{String.trim(question)}
      """

    [
      system_message(editor_assistant_instructions()),
      user_message(prompt)
    ]
  end

  @spec stats(messages()) :: stats()
  def stats(messages) when is_list(messages) do
    by_role =
      Enum.reduce(messages, %{}, fn message, acc ->
        role = Map.get(message, :role, "unknown")
        content = Map.get(message, :content, "")
        chars = String.length(content)

        Map.update(
          acc,
          role,
          %{message_count: 1, chars: chars, estimated_tokens: estimate_tokens(chars)},
          fn role_stats ->
            chars = role_stats.chars + chars

            %{
              message_count: role_stats.message_count + 1,
              chars: chars,
              estimated_tokens: estimate_tokens(chars)
            }
          end
        )
      end)

    total_chars =
      by_role
      |> Map.values()
      |> Enum.reduce(0, &(&1.chars + &2))

    %{
      message_count: length(messages),
      total_chars: total_chars,
      estimated_tokens: estimate_tokens(total_chars),
      by_role: by_role
    }
  end

  @spec folder_files_for_prompt(String.t()) :: [prompt_file()]
  def folder_files_for_prompt(root_path) when is_binary(root_path) do
    expanded_root = Path.expand(root_path)

    expanded_root
    |> list_files_recursive()
    |> Enum.filter(&wanted_file?/1)
    |> Enum.map(fn path ->
      %{
        path: path,
        content: read_prompt_file(path)
      }
    end)
    |> trim_files_to_budget(@editor_total_max_chars)
  end

  @spec editor_assistant_instructions() :: String.t()
  def editor_assistant_instructions do
    """
    You are a concise Elixir and Phoenix coding assistant embedded in a text editor.

    Answer only using the provided file contents and the user's question.
    If the provided files do not contain enough information, say so plainly.
    Prefer short, practical answers.

    Formatting rules:
    - Use markdown code fences for every code example.
    - Always include a language tag when possible, such as ```elixir, ```javascript, or ```text.
    - Keep prose outside code fences.
    - Do not wrap your entire response in a single code block.
    """
  end

  @spec editor_refactor_instructions() :: String.t()
  def editor_refactor_instructions do
    """
    You are a careful Elixir and Phoenix refactoring assistant embedded in a text editor.

    The prompt includes one primary target file and zero or more supporting files.
    Treat the primary target as the file to refactor. Treat supporting files as context only.

    Refactor guidance:
    - Refactor the primary target file directly.
    - Use supporting files to preserve behavior and interfaces.
    - If supporting files are partial or incomplete, still refactor the primary file as far as the provided context safely allows.
    - If the target file appears truncated, say that plainly before proposing changes.
    - Prefer behavior-preserving improvements unless the user explicitly requests a broader redesign.

    Formatting rules:
    - Start with a short assessment of what should change.
    - Then provide the refactored code in markdown code fences.
    - Always include a language tag when possible, such as ```elixir, ```javascript, or ```text.
    - Keep prose outside code fences.
    - Do not wrap your entire response in a single code block.
    """
  end

  @spec system_message(String.t()) :: message()
  def system_message(content) when is_binary(content) do
    %{role: "system", content: String.trim(content)}
  end

  @spec user_message(String.t()) :: message()
  def user_message(content) when is_binary(content) do
    %{role: "user", content: String.trim(content)}
  end

  @spec assistant_message(String.t()) :: message()
  def assistant_message(content) when is_binary(content) do
    %{role: "assistant", content: String.trim(content)}
  end

  @spec truncate_content(String.t(), pos_integer()) :: String.t()
  def truncate_content(content, max_chars) when is_binary(content) and max_chars > 0 do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <>
        "\n\n[Truncated before sending to the model.]"
    else
      content
    end
  end

  @spec list_files_recursive(String.t()) :: [String.t()]
  def list_files_recursive(root_path) when is_binary(root_path) do
    do_list_files_recursive(Path.expand(root_path))
    |> Enum.sort()
  end

  defp do_list_files_recursive(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn name ->
          full_path = Path.join(path, name)

          case File.stat(full_path) do
            {:ok, %{type: :directory}} ->
              if skip_directory?(full_path) do
                []
              else
                do_list_files_recursive(full_path)
              end

            {:ok, %{type: :regular}} ->
              [full_path]

            _ ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  @spec wanted_file?(String.t()) :: boolean()
  def wanted_file?(path) when is_binary(path) do
    Path.extname(path) in @default_allowed_extensions and
      not skipped_directory_path?(path) and
      not generated_path?(path) and
      not skip_file?(path)
  end

  defp skip_directory?(path) do
    basename = Path.basename(path)
    basename in @skipped_directory_names or generated_path?(path)
  end

  defp skip_file?(path) do
    basename = Path.basename(path)
    String.starts_with?(basename, ".") and basename not in [".formatter.exs"]
  end

  defp generated_path?(path) do
    parts = Path.split(path)

    Enum.any?(@skipped_path_segments, &contains_segments?(parts, &1))
  end

  defp skipped_directory_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in @skipped_directory_names))
  end

  defp contains_segments?(parts, segments) do
    segment_count = length(segments)

    parts
    |> Enum.chunk_every(segment_count, 1, :discard)
    |> Enum.any?(&(&1 == segments))
  end

  defp read_prompt_file(path) do
    path
    |> File.read!()
    |> truncate_content(@editor_file_max_chars)
  rescue
    _error -> "[Unreadable file omitted.]"
  end

  defp prompt_mode(question, nil) do
    if refactor_question?(question), do: :refactor, else: :question
  end

  defp prompt_mode(question, _primary_path) do
    if refactor_question?(question), do: :refactor, else: :question
  end

  defp refactor_question?(question) do
    normalized = String.downcase(question)

    Enum.any?(@refactor_keywords, &String.contains?(normalized, &1))
  end

  defp question_prompt(files, question, primary_path) do
    """
    #{primary_target_line(primary_path)}

    Files:

    #{files_to_prompt(files)}

    Question:
    #{question}
    """
  end

  defp refactor_prompt(files, question, primary_path) do
    {primary_file, supporting_files} = split_primary_and_supporting_files(files, primary_path)

    """
    Primary refactor target:
    #{primary_file_block(primary_file, primary_path)}

    Supporting context files:
    #{supporting_files_block(supporting_files)}

    Refactor request:
    #{question}
    """
  end

  defp primary_target_line(nil), do: "Primary target: none explicitly selected"

  defp primary_target_line(primary_path) do
    "Primary target: #{primary_path}"
  end

  defp split_primary_and_supporting_files(files, nil) do
    case files do
      [first | rest] -> {first, rest}
      [] -> {nil, []}
    end
  end

  defp split_primary_and_supporting_files(files, primary_path) do
    case Enum.split_with(files, &(&1.path == primary_path)) do
      {[primary_file | _], others} ->
        {primary_file, others}

      {[], others} ->
        split_primary_and_supporting_files(others, nil)
    end
  end

  defp primary_file_block(nil, primary_path) do
    """
    Path: #{primary_path || "[unknown]"}
    [Primary target file content was not provided.]
    """
    |> String.trim()
  end

  defp primary_file_block(%{path: path, content: content}, _primary_path) do
    file_block(%{path: path, content: content})
  end

  defp supporting_files_block([]), do: "[No supporting files provided.]"

  defp supporting_files_block(files) do
    files_to_prompt(files)
  end

  defp files_to_prompt(files) do
    files
    |> Enum.map(&file_block/1)
    |> Enum.join("\n\n")
  end

  defp file_block(%{path: path, content: content}) do
    language = language_tag(path)

    """
    File: #{path}
    ```#{language}
    #{content}
    ```
    """
    |> String.trim()
  end

  defp language_tag(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "heex"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "tsx"
      ".json" -> "json"
      ".md" -> "markdown"
      _ -> "text"
    end
  end

  defp trim_files_to_budget(files, max_chars) do
    {kept, _used_chars} =
      Enum.reduce_while(files, {[], 0}, fn file, {acc, used_chars} ->
        next_size = used_chars + String.length(file.content)

        if next_size > max_chars and acc != [] do
          {:halt, {Enum.reverse(acc), used_chars}}
        else
          {:cont, {[file | acc], min(next_size, max_chars)}}
        end
      end)

    kept
  end

  defp estimate_tokens(chars) when is_integer(chars) and chars >= 0 do
    div(chars + 3, 4)
  end
end
