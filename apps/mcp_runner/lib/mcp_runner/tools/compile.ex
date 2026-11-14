defmodule McpRunner.Tools.Compile do
  @moduledoc "Compile the configured Mix workspace (requires explicit local execution opt-in)."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    %{}
  end

  @impl true
  @spec execute(map(), term()) :: {:reply, term(), term()}
  def execute(_params, frame) do
    response =
      case McpRunner.Operations.compile() do
        {:ok, data} -> Response.json(Response.tool(), data)
        {:error, reason} -> Response.error(Response.tool(), reason)
      end

    {:reply, response, frame}
  end
end
