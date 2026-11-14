defmodule McpRunner.Tools.ListFiles do
  @moduledoc "List direct children of an authorized workspace directory (no recursion or symlinks)."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :path, :string, default: ".", description: "Relative directory path"
  end

  @impl true
  def execute(params, frame) do
    result = McpRunner.Operations.list_files(Map.get(params, :path, "."))

    response =
      case result do
        {:ok, data} -> Response.json(Response.tool(), data)
        {:error, reason} -> Response.error(Response.tool(), reason)
      end

    {:reply, response, frame}
  end
end
