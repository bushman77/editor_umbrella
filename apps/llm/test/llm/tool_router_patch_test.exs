defmodule Llm.ToolRouterPatchTest do
  use ExUnit.Case, async: false

  alias Llm.ToolRouter

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "tool-router-patch-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "sample.txt")
    File.write!(path, "red red\n")
    previous_root = System.get_env("LLM_TOOL_WORKSPACE_ROOT")
    System.put_env("LLM_TOOL_WORKSPACE_ROOT", root)

    on_exit(fn ->
      if previous_root do
        System.put_env("LLM_TOOL_WORKSPACE_ROOT", previous_root)
      else
        System.delete_env("LLM_TOOL_WORKSPACE_ROOT")
      end

      File.rm_rf!(root)
    end)

    %{root: root, path: path}
  end

  test "patches only the first match by default", %{root: root, path: path} do
    assert {:ok, %{occurrences_replaced: 1}} =
             ToolRouter.call("editor_patch_file", %{
               "root" => root,
               "path" => "sample.txt",
               "search" => "red",
               "replace" => "blue"
             })

    assert File.read!(path) == "blue red\n"
  end

  test "patches all matches when requested", %{root: root, path: path} do
    assert {:ok, %{occurrences_replaced: 2}} =
             ToolRouter.call("editor_patch_file", %{
               "root" => root,
               "path" => "sample.txt",
               "search" => "red",
               "replace" => "blue",
               "all" => true
             })

    assert File.read!(path) == "blue blue\n"
  end

  test "unknown tools still return a structured error" do
    assert {:error, %{error: "unknown_tool", tool: "not_a_tool"}} =
             ToolRouter.call("not_a_tool", %{})
  end
end
