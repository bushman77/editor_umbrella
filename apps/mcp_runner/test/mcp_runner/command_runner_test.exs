defmodule McpRunner.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias McpRunner.CommandRunner

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-command-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "preserves a completed command's exit status", %{root: root} do
    assert {:ok, %{exit_status: 23, timed_out: false}} =
             CommandRunner.run("sh", ["-c", "exit 23"], root, 2)
  end

  test "expires a long-running command", %{root: root} do
    assert {:ok, %{exit_status: 124, timed_out: true}} =
             CommandRunner.run("sh", ["-c", "sleep 5"], root, 0.2, 0.2)
  end

  test "timeout terminates background children in the same process group", %{root: root} do
    marker = Path.join(root, "survived")
    script = "(sleep 1; printf survived > \"$1\") & wait"

    assert {:ok, %{exit_status: 124, timed_out: true}} =
             CommandRunner.run("sh", ["-c", script, "sh", marker], root, 0.2, 0.2)

    # If the background child survived, it would write the marker after 1 second.
    Process.sleep(1_400)
    refute File.exists?(marker)
  end

  test "escalates to KILL when a process ignores TERM", %{root: root} do
    script = "trap '' TERM; while :; do sleep 1; done"

    assert {:ok, %{exit_status: 137, timed_out: true}} =
             CommandRunner.run("sh", ["-c", script], root, 0.2, 0.2)
  end
end
