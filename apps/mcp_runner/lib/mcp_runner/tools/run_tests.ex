defmodule McpRunner.Tools.RunTests do
  @moduledoc "Run mix test in the configured workspace, optionally for one *_test.exs file."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :path, :string, description: "Optional relative *_test.exs file; omit to run all tests"
  end

  @impl true
  @spec execute(map(), term()) :: {:reply, term(), term()}
  def execute(params, frame) do
    response =
      case McpRunner.Operations.run_tests(Map.get(params, :path)) do
        {:ok, data} -> Response.json(Response.tool(), data)
        {:error, reason} -> Response.error(Response.tool(), reason)
      end

    {:reply, response, frame}
  end
end
