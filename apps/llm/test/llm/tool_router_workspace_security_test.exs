defmodule Llm.ToolRouterWorkspaceSecurityTest do
  use ExUnit.Case, async: false

  alias Llm.ToolRouter

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    base = Path.join(System.tmp_dir!(), "llm-tool-security-#{suffix}")
    trusted = Path.join(base, "trusted")
    project = Path.join(trusted, "project")
    outside = Path.join(base, "outside")

    File.mkdir_p!(project)
    File.mkdir_p!(outside)
    File.write!(Path.join(project, "sample.txt"), "red red\n")
    File.write!(Path.join(outside, "secret.txt"), "secret\n")

    previous_root = System.get_env("LLM_TOOL_WORKSPACE_ROOT")
    System.put_env("LLM_TOOL_WORKSPACE_ROOT", trusted)

    on_exit(fn ->
      if previous_root do
        System.put_env("LLM_TOOL_WORKSPACE_ROOT", previous_root)
      else
        System.delete_env("LLM_TOOL_WORKSPACE_ROOT")
      end

      File.rm_rf!(base)
    end)

    %{project: project, trusted: trusted, outside: outside}
  end

  test "allows read, write and patch inside the trusted root", %{project: project} do
    assert {:ok, %{content: "red red\n"}} =
             ToolRouter.call("editor_read_file", %{"root" => project, "path" => "sample.txt"})

    assert {:ok, %{bytes_written: 5}} =
             ToolRouter.call("editor_write_file", %{
               "root" => project,
               "path" => "nested/new.txt",
               "content" => "hello"
             })

    assert File.read!(Path.join(project, "nested/new.txt")) == "hello"

    assert {:ok, %{occurrences_replaced: 1}} =
             ToolRouter.call("editor_patch_file", %{
               "root" => project,
               "path" => "sample.txt",
               "search" => "red",
               "replace" => "blue"
             })

    assert File.read!(Path.join(project, "sample.txt")) == "blue red\n"
  end

  test "denies all three file operations without trusted configuration", %{project: project} do
    System.delete_env("LLM_TOOL_WORKSPACE_ROOT")

    for {tool, extra} <- [
          {"editor_read_file", %{}},
          {"editor_write_file", %{"content" => "bad"}},
          {"editor_patch_file", %{"search" => "red", "replace" => "bad"}}
        ] do
      assert {:error, %{error: "trusted_workspace_root_not_configured"}} =
               ToolRouter.call(
                 tool,
                 Map.merge(%{"root" => project, "path" => "sample.txt"}, extra)
               )
    end
  end

  test "rejects a caller-supplied root outside the trusted directory", %{outside: outside} do
    for {tool, extra} <- [
          {"editor_read_file", %{}},
          {"editor_write_file", %{"content" => "bad"}},
          {"editor_patch_file", %{"search" => "secret", "replace" => "bad"}}
        ] do
      assert {:error, %{error: "workspace_root_denied"}} =
               ToolRouter.call(
                 tool,
                 Map.merge(%{"root" => outside, "path" => "secret.txt"}, extra)
               )
    end

    assert File.read!(Path.join(outside, "secret.txt")) == "secret\n"
  end

  test "rejects parent traversal from an authorized project", %{project: project} do
    assert {:error, %{error: "path_outside_workspace"}} =
             ToolRouter.call("editor_read_file", %{
               "root" => project,
               "path" => "../../outside/secret.txt"
             })
  end

  test "rejects symlink file targets for read, patch and overwrite", %{
    project: project,
    outside: outside
  } do
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(project, "link.txt"))

    for {tool, extra} <- [
          {"editor_read_file", %{}},
          {"editor_write_file", %{"content" => "bad"}},
          {"editor_patch_file", %{"search" => "secret", "replace" => "bad"}}
        ] do
      assert {:error, %{error: "symlink_path_denied"}} =
               ToolRouter.call(tool, Map.merge(%{"root" => project, "path" => "link.txt"}, extra))
    end

    assert File.read!(Path.join(outside, "secret.txt")) == "secret\n"
  end

  test "rejects a symlink in the parent of a newly written file", %{
    project: project,
    outside: outside
  } do
    File.ln_s!(outside, Path.join(project, "redirect"))

    assert {:error, %{error: "symlink_path_denied"}} =
             ToolRouter.call("editor_write_file", %{
               "root" => project,
               "path" => "redirect/new.txt",
               "content" => "bad"
             })

    refute File.exists?(Path.join(outside, "new.txt"))
  end

  test "rejects a trusted root that itself uses a symlink", %{
    trusted: trusted,
    project: project
  } do
    File.ln_s!(project, Path.join(trusted, "project-link"))

    assert {:error, %{error: "symlink_path_denied"}} =
             ToolRouter.call("editor_read_file", %{
               "root" => Path.join(trusted, "project-link"),
               "path" => "sample.txt"
             })
  end

  test "directory listing does not traverse symlink directories", %{
    project: project,
    outside: outside
  } do
    File.ln_s!(outside, Path.join(project, "redirect"))

    assert {:ok, %{files: files}} =
             ToolRouter.call("editor_list_files", %{
               "root" => project,
               "path" => ".",
               "recursive" => true
             })

    refute Enum.any?(files, fn file -> String.contains?(file.path, "secret.txt") end)
  end

  test "the editor workspace authorizes tools when the env var is unset", %{
    project: project,
    outside: outside
  } do
    System.delete_env("LLM_TOOL_WORKSPACE_ROOT")

    ToolRouter.with_workspace_root(project, fn ->
      assert {:ok, %{content: "red red\n"}} =
               ToolRouter.call("editor_read_file", %{"root" => project, "path" => "sample.txt"})

      assert {:error, %{error: "workspace_root_denied"}} =
               ToolRouter.call("editor_read_file", %{"root" => outside, "path" => "secret.txt"})

      # A wider root than the open workspace is refused too.
      assert {:error, %{error: "workspace_root_denied"}} =
               ToolRouter.call("editor_list_files", %{"root" => Path.dirname(project)})
    end)

    assert {:error, %{error: "trusted_workspace_root_not_configured"}} =
             ToolRouter.call("editor_read_file", %{"root" => project, "path" => "sample.txt"})
  end

  test "the env var still wins over the editor workspace", %{project: project, outside: outside} do
    ToolRouter.with_workspace_root(outside, fn ->
      assert {:ok, %{content: "red red\n"}} =
               ToolRouter.call("editor_read_file", %{"root" => project, "path" => "sample.txt"})

      assert {:error, %{error: "workspace_root_denied"}} =
               ToolRouter.call("editor_read_file", %{"root" => outside, "path" => "secret.txt"})
    end)
  end
end
