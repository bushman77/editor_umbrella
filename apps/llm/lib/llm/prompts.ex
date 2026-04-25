defmodule Llm.Prompts do
  @moduledoc """
  Prompt builders for the local LLM integration.

  This module returns chat-style message lists that can be passed directly to
  `Llm.chat/1` or `Llm.chat_raw/1`.
  """

  @editor_file_max_chars 12_000

  @type role :: String.t()
  @type message :: %{role: role(), content: String.t()}
  @type messages :: [message()]

  @spec editor_file_question(String.t(), String.t(), String.t()) :: messages()
  def editor_file_question(path, content, question)
      when is_binary(path) and is_binary(content) and is_binary(question) do
    truncated_content = truncate_content(content, @editor_file_max_chars)

    [
      system_message(editor_assistant_instructions()),
      user_message("""
      File path: #{path}

      File contents:
      #{truncated_content}

      Question:
      #{String.trim(question)}
      """)
    ]
  end

  @spec editor_assistant_instructions() :: String.t()
  def editor_assistant_instructions do
    """
    You are a concise Elixir and Phoenix coding assistant embedded in a text editor.

    Answer only using the provided file contents and the user's question.
    If the file does not contain enough information, say so plainly.
    Prefer short, practical answers.

    Formatting rules:
    - Use markdown code fences for every code example.
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
end
