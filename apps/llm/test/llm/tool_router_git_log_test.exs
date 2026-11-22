defmodule Llm.ToolRouterGitLogTest do
  use ExUnit.Case, async: true

  test "parses hash, date and subject from the tab-separated log format" do
    output =
      "aac0f7a\t2026-11-22 12:29\tRepeat the question when the tool-round limit hits\n" <>
        "9c16ebb\t2026-11-22 10:58\tReplay conversation history into editor LLM requests\n"

    assert Llm.ToolRouter.parse_git_log(output) == [
             %{
               hash: "aac0f7a",
               date: "2026-11-22 12:29",
               message: "Repeat the question when the tool-round limit hits"
             },
             %{
               hash: "9c16ebb",
               date: "2026-11-22 10:58",
               message: "Replay conversation history into editor LLM requests"
             }
           ]
  end

  test "keeps tabs inside the subject and tolerates an empty subject" do
    assert [%{message: "a\tb"}, %{hash: "def5678", date: "2026-11-21 09:00", message: ""}] =
             Llm.ToolRouter.parse_git_log(
               "abc1234\t2026-11-22 08:00\ta\tb\ndef5678\t2026-11-21 09:00\n"
             )
  end
end
