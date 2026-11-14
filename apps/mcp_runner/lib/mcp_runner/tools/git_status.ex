defmodule McpRunner.Tools.GitStatus do
  @moduledoc "Show Git branch and uncommitted changes for the configured workspace."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    %{}
  end

  @impl true
  def execute(_params, frame) do
    response =
      case McpRunner.Operations.git_status() do
        {:ok, data} -> Response.json(Response.tool(), data)
        {:error, reason} -> Response.error(Response.tool(), reason)
      end

    {:reply, response, frame}
  end
end
