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
end
