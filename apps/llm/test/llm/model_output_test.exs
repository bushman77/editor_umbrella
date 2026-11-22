defmodule Llm.ModelOutputTest do
  use ExUnit.Case, async: true

  alias Llm.ModelOutput

  describe "strip_reasoning/1" do
    test "removes complete think blocks" do
      assert ModelOutput.strip_reasoning("<think>\nplan it\n</think>\n\nThe answer.") ==
               "The answer."
    end

    test "drops reasoning when the template opened the think block in the prompt" do
      assert ModelOutput.strip_reasoning("weighing options...\n</think>\n\nStep 5.") == "Step 5."
    end

    test "returns empty text when reasoning was cut off before any answer" do
      assert ModelOutput.strip_reasoning("<think>still thinking about") == ""
    end

    test "leaves ordinary answers untouched apart from trimming" do
      assert ModelOutput.strip_reasoning("  plain answer \n") == "plain answer"
      assert ModelOutput.strip_reasoning(nil) == ""
    end
  end

  describe "parse_tool_calls/1" do
    test "parses Qwen XML tool calls and decodes non-string values" do
      text = """
      <tool_call>
      <function=editor_read_file>
      <parameter=root>
      /home/default/SunRacer
      </parameter>
      <parameter=path>
      apps/sunracer/lib/sunracer/story.ex
      </parameter>
      <parameter=max_bytes>
      4000
      </parameter>
      </function>
      </tool_call>
      """

      assert {:ok, [call]} = ModelOutput.parse_tool_calls(text)
      assert call.name == "editor_read_file"

      assert call.arguments == %{
               "root" => "/home/default/SunRacer",
               "path" => "apps/sunracer/lib/sunracer/story.ex",
               "max_bytes" => 4000
             }

      assert %{"id" => id, "type" => "function", "function" => function} = call.raw
      assert id == call.id
      assert function["name"] == "editor_read_file"
      assert Jason.decode!(function["arguments"]) == call.arguments
    end

    test "parses several XML calls in one reply" do
      text = """
      <tool_call>
      <function=editor_list_files>
      <parameter=root>
      /w
      </parameter>
      </function>
      </tool_call>
      <tool_call>
      <function=editor_git_log>
      <parameter=root>
      /w
      </parameter>
      </function>
      </tool_call>
      """

      assert {:ok, [first, second]} = ModelOutput.parse_tool_calls(text)
      assert first.name == "editor_list_files"
      assert second.name == "editor_git_log"
      assert first.id != second.id
    end

    test "parses Hermes-style JSON inside tool_call tags" do
      text = """
      <tool_call>
      {"name": "editor_search_workspace", "arguments": {"root": "/w", "query": "first_pay"}}
      </tool_call>
      """

      assert {:ok, [call]} = ModelOutput.parse_tool_calls(text)
      assert call.name == "editor_search_workspace"
      assert call.arguments == %{"root" => "/w", "query" => "first_pay"}
    end

    test "accepts arguments encoded as a JSON string" do
      text =
        ~s(<tool_call>{"name": "editor_list_files", "arguments": "{\\"root\\": \\"/w\\"}"}</tool_call>)

      assert {:ok, [call]} = ModelOutput.parse_tool_calls(text)
      assert call.arguments == %{"root" => "/w"}
    end

    test "keeps the bare JSON line fallback, including Elixir heredoc values" do
      text =
        ~s(Let me write it.\n{"name": "editor_write_file", "arguments": {"path": "a.ex", "content": """\ndefmodule A do\nend\n"""}})

      assert {:ok, [call]} = ModelOutput.parse_tool_calls(text)
      assert call.name == "editor_write_file"
      assert call.arguments["content"] == "defmodule A do\nend"
    end

    test "returns :error for prose" do
      assert ModelOutput.parse_tool_calls("Destroying Corsair-17 returns the pilot to step 5.") ==
               :error

      assert ModelOutput.parse_tool_calls(nil) == :error
    end
  end

  describe "tool_call_text?/1" do
    test "detects each supported shape and ignores prose" do
      assert ModelOutput.tool_call_text?("<tool_call>\n<function=x>\n</function>\n</tool_call>")
      assert ModelOutput.tool_call_text?("<function=x>\n</function>")
      assert ModelOutput.tool_call_text?(~s({"name": "x", "arguments": {}}))
      refute ModelOutput.tool_call_text?("Use editor_read_file to read it.")
      refute ModelOutput.tool_call_text?(nil)
    end
  end
end
