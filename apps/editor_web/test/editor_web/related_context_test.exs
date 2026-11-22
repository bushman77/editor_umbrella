defmodule EditorWeb.RelatedContextTest do
  use ExUnit.Case, async: true

  alias EditorWeb.RelatedContext

  @client_specs [
    %{
      name: "chat_completion",
      spec:
        "@spec chat_completion([chat_message()], keyword()) :: {:ok, chat_completion()} | {:error, term()}",
      head:
        "def chat_completion(messages, opts \\\\ []) when is_list(messages) and is_list(opts) do"
    },
    %{
      name: "tool_result_message",
      spec: "@spec tool_result_message(tool_call(), map() | String.t()) :: map()",
      head: "def tool_result_message(%{id: id, name: name}, result) do"
    }
  ]

  test "sends specs for the functions the current file calls" do
    section =
      RelatedContext.format("apps/llm/lib/llm/tool_loop.ex", [
        %{path: "apps/llm/lib/llm/client.ex", relationship: "uses", functions: @client_specs},
        %{path: "apps/llm/lib/llm.ex", relationship: "used by", functions: []}
      ])

    assert section =~ "Current file: apps/llm/lib/llm/tool_loop.ex"
    assert section =~ "Dependencies (current file uses these):\n  - apps/llm/lib/llm/client.ex\n"

    assert section =~
             "      @spec chat_completion([chat_message()], keyword()) :: {:ok, chat_completion()} | {:error, term()}"

    assert section =~ "      @spec tool_result_message(tool_call(), map() | String.t()) :: map()"
    assert section =~ "Consumers (these use the current file):\n  - apps/llm/lib/llm.ex"
    refute section =~ "def chat_completion"
  end

  test "falls back to the head, without its do, when a function has no spec" do
    assert RelatedContext.contract_lines([
             %{name: "ready?", spec: nil, head: "def ready? do"},
             %{name: "port", spec: "", head: "def port, do: Application.get_env(:llm, :port)"}
           ]) == ["def ready?", "def port"]
  end

  test "multi-clause functions appear once, preferring a clause with a spec" do
    clauses = [
      %{name: "call", spec: nil, head: ~s|def call("mix_test", args) when is_map(args) do|},
      %{name: "call", spec: "@spec call(tool_name(), tool_args()) :: tool_result()", head: "x"},
      %{name: "tools", spec: "@spec tools() :: [map()]", head: "def tools do"}
    ]

    assert RelatedContext.contract_lines(clauses) == [
             "@spec call(tool_name(), tool_args()) :: tool_result()",
             "@spec tools() :: [map()]"
           ]
  end

  test "files you switched on in the tab bar are sent even when only weakly related" do
    section =
      RelatedContext.format("lib/a.ex", [
        %{path: "lib/b.ex", relationship: "related", functions: []}
      ])

    assert section =~ "Other files you included:\n  - lib/b.ex"
  end

  test "nothing selected or nothing related sends nothing" do
    assert RelatedContext.format(nil, [%{path: "lib/b.ex", relationship: "uses"}]) == ""
    assert RelatedContext.format("lib/a.ex", []) == ""
  end
end
