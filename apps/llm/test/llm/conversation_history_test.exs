defmodule Llm.ConversationHistoryTest do
  use ExUnit.Case, async: true

  alias Llm.ConversationHistory

  defp user(content), do: %{role: "user", content: content}
  defp assistant(content), do: %{role: "assistant", content: content}

  test "replays questions and answers oldest first" do
    stored = [user("Where is credit payout?"), assistant("In Core.Credits.pay/2.")]

    assert ConversationHistory.prompt_messages(stored) == stored
  end

  test "keeps the newest turns when the budget is tight" do
    stored = [
      user("old question"),
      assistant("old answer"),
      user("new question"),
      assistant("new answer")
    ]

    assert ConversationHistory.prompt_messages(stored, max_chars: 22) == [
             user("new question"),
             assistant("new answer")
           ]
  end

  test "never starts with an assistant message" do
    stored = [user("a long question that will not fit"), assistant("short"), user("next")]

    assert ConversationHistory.prompt_messages(stored, max_chars: 10) == [user("next")]
  end

  test "trims long answers so one reply cannot take the whole budget" do
    stored = [user("q"), assistant(String.duplicate("x", 50))]

    [_question, %{content: answer}] =
      ConversationHistory.prompt_messages(stored, max_assistant_chars: 10)

    assert String.starts_with?(answer, String.duplicate("x", 10))
    assert answer =~ "[earlier answer trimmed]"
  end

  test "skips blank, unknown-role and non-text messages and accepts string keys" do
    stored = [
      %{"role" => "user", "content" => "  string keys  "},
      user("   "),
      %{role: "tool", content: "tool output"},
      %{role: "assistant", content: nil},
      :junk
    ]

    assert ConversationHistory.prompt_messages(stored) == [user("string keys")]
  end

  test "char_count sums message contents" do
    assert ConversationHistory.char_count([user("abc"), assistant("de")]) == 5
  end
end
