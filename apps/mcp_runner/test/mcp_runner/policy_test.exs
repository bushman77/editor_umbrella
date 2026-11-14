defmodule McpRunner.PolicyTest do
  use ExUnit.Case, async: false

  alias McpRunner.Policy

  setup do
    original_root = System.get_env("EDITOR_MCP_WORKSPACE_ROOT")
    original_permission = System.get_env("EDITOR_MCP_ALLOW_EXECUTION")
    root = Path.join(System.tmp_dir!(), "mcp-runner-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "sample.ex"]), "defmodule Sample, do: nil\n")
    System.put_env("EDITOR_MCP_WORKSPACE_ROOT", root)
    System.delete_env("EDITOR_MCP_ALLOW_EXECUTION")

    on_exit(fn ->
      restore_env("EDITOR_MCP_WORKSPACE_ROOT", original_root)
      restore_env("EDITOR_MCP_ALLOW_EXECUTION", original_permission)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "limits file reads to configured workspace", %{root: root} do
    assert {:ok, ^root, _path} = Policy.existing_path("lib/sample.ex", :file)
    assert {:error, _} = Policy.existing_path("../outside.ex", :file)
    assert {:error, _} = Policy.existing_path("/etc/passwd", :file)
  end

  test "refuses symbolic links that leave the workspace", %{root: root} do
    File.ln_s!("/etc/passwd", Path.join([root, "lib", "linked.ex"]))
    assert {:error, _} = Policy.existing_path("lib/linked.ex", :file)
  end

  test "refuses hidden credentials and generated directories", %{root: root} do
    File.write!(Path.join(root, ".env"), "KEY=secret")
    assert {:error, _} = Policy.existing_path(".env", :file)
    assert {:error, _} = Policy.existing_path(".git/config", :file)
  end

  test "execution requires explicit local permission" do
    refute Policy.execution_allowed?()
    System.put_env("EDITOR_MCP_ALLOW_EXECUTION", "1")
    assert Policy.execution_allowed?()
  end

  test "compile execution is disabled by default" do
    assert {:error, message} = McpRunner.Operations.compile()
    assert message =~ "disabled"
  end

  test "read returns local file contents" do
    assert {:ok, %{content: "defmodule Sample, do: nil\n", truncated: false}} =
             McpRunner.Operations.read_file("lib/sample.ex")
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
