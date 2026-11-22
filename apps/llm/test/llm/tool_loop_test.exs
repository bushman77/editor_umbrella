defmodule Llm.ToolLoopTest do
  use ExUnit.Case, async: true

  alias Llm.ToolLoop

  test "failed tool results carry an instruction not to guess" do
    result = %{ok: false, error: %{error: "workspace_root_denied", root: "/home/default"}}

    annotated = ToolLoop.annotate_tool_result(result)

    assert annotated.error == result.error
    assert annotated.note =~ "This tool call failed"
    assert annotated.note =~ "Do not answer from guesses"
  end

  test "successful tool results are left untouched" do
    result = %{ok: true, result: %{content: "defmodule A do\nend\n"}}

    assert ToolLoop.annotate_tool_result(result) == result
  end

  test "the note survives encoding into the tool message sent to the model" do
    tool_call = %{id: "call_1", name: "editor_search_workspace"}

    message =
      %{ok: false, error: %{error: "trusted_workspace_root_not_configured"}}
      |> ToolLoop.annotate_tool_result()
      |> then(&Llm.Client.tool_result_message(tool_call, &1))

    assert %{"note" => note, "error" => %{"error" => "trusted_workspace_root_not_configured"}} =
             Jason.decode!(message.content)

    assert note =~ "Tell the user which tool failed"
  end

  describe "final_answer_instruction/2" do
    test "repeats the original question when the round limit is hit" do
      messages = [
        %{role: "system", content: "rules"},
        %{
          role: "user",
          content: "Open buffers: ...\n\nUser question:\nwhere is record_turn defined?\n"
        },
        %{role: "assistant", content: "", tool_calls: []},
        %{role: "tool", content: String.duplicate("caller ", 500)}
      ]

      instruction = ToolLoop.final_answer_instruction(messages, 6)

      assert instruction =~ "maximum tool-call round limit of 6"
      assert instruction =~ "The question you must answer:\nwhere is record_turn defined?"
      refute instruction =~ "Open buffers"
    end

    test "uses the last marker, so an open buffer quoting the marker does not win" do
      content =
        "FILE: editor_llm.ex\n  User question:\n  \#{question}\n\nUser question:\nreal one"

      assert ToolLoop.original_question([%{"role" => "user", "content" => content}]) == "real one"
    end

    test "plain prompts are used whole, and no user message means no question" do
      assert ToolLoop.original_question([%{role: "user", content: " list files "}]) ==
               "list files"

      assert ToolLoop.original_question([%{role: "system", content: "x"}]) == nil

      refute ToolLoop.final_answer_instruction([], 4) =~ "The question you must answer"
    end
  end
end
