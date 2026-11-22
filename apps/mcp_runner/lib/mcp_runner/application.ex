defmodule McpRunner.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Never start a server (or consume stdin) during ordinary editor startup.
    children =
      if System.get_env("EDITOR_MCP_ENABLED") == "1" do
        [{McpRunner.Server, transport: :stdio}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: McpRunner.Supervisor)
  end
end
