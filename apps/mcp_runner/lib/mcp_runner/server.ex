defmodule McpRunner.Server do
  @moduledoc """
  Local-only MCP server for explicitly permitted developer operations.

  Uses STDIO, not an HTTP listener. The process must be launched explicitly
  with EDITOR_MCP_ENABLED=1 and a trusted EDITOR_MCP_WORKSPACE_ROOT.
  """

  use Anubis.Server,
    name: "editor-umbrella-local-runner",
    version: "0.1.0",
    capabilities: [:tools]

  component McpRunner.Tools.ReadFile, name: "editor_read_file"
  component McpRunner.Tools.ListFiles, name: "editor_list_files"
  component McpRunner.Tools.GitStatus, name: "editor_git_status"
  component McpRunner.Tools.Compile, name: "mix_compile"
  component McpRunner.Tools.RunTests, name: "mix_test"
end
