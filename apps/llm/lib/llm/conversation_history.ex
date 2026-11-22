defmodule Llm.ConversationHistory do
  @moduledoc """
  Turns stored conversation messages into prompt messages for the next request.

  Only the user's questions and the model's final answers are replayed. Tool
  calls and tool results from earlier turns are not: they are large and the
  model can repeat a lookup when it needs one.

  Pure: callers pass the stored messages and a character budget.

    * Each message is trimmed (`:max_user_chars`, `:max_assistant_chars`) so one
      long answer full of code cannot crowd out everything else.
    * The oldest turns are dropped until the rest fit in `:max_chars`.
    * The result always starts with a user message, so the chat template never
      sees an assistant turn with no question before it.
  """

  @default_max_chars 12_000
  @default_max_user_chars 1_500
  @default_max_assistant_chars 2_500
  @trim_marker "\n[earlier answer trimmed]"

  @type message :: %{role: String.t(), content: String.t()}

  @type opts :: [
          max_chars: pos_integer(),
          max_user_chars: pos_integer(),
          max_assistant_chars: pos_integer()
        ]

  @doc "Prompt-ready history messages, oldest first, within the character budget."
  @spec prompt_messages([map()], opts()) :: [message()]
  def prompt_messages(stored_messages, opts \\ []) when is_list(stored_messages) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)

    stored_messages
    |> Enum.flat_map(&normalize(&1, opts))
    |> drop_leading_assistant()
    |> fit_budget(max_chars)
    |> drop_leading_assistant()
  end

  @doc "Total characters of message contents."
  @spec char_count([message()]) :: non_neg_integer()
  def char_count(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn %{content: content}, acc -> acc + String.length(content) end)
  end

  defp normalize(message, opts) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")

    with role when role in ["user", "assistant"] <- role,
         content when is_binary(content) <- content,
         trimmed when trimmed != "" <- String.trim(content) do
      [%{role: role, content: trim(trimmed, limit_for(role, opts))}]
    else
      _other -> []
    end
  end

  defp normalize(_message, _opts), do: []

  defp limit_for("user", opts), do: Keyword.get(opts, :max_user_chars, @default_max_user_chars)

  defp limit_for("assistant", opts),
    do: Keyword.get(opts, :max_assistant_chars, @default_max_assistant_chars)

  defp trim(content, max_chars) do
    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <> @trim_marker
    else
      content
    end
  end

  # Walk from the newest message backwards, keeping messages while they fit.
  defp fit_budget(messages, max_chars) do
    {kept, _used} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn message, {kept, used} ->
        size = String.length(message.content)

        if used + size > max_chars do
          {:halt, {kept, used}}
        else
          {:cont, {[message | kept], used + size}}
        end
      end)

    kept
  end

  defp drop_leading_assistant([%{role: "assistant"} | rest]), do: drop_leading_assistant(rest)
  defp drop_leading_assistant(messages), do: messages
end
