defmodule McpRunner.Tools.ReadFile do
  @moduledoc "Read a UTF-8 source file inside the configured local workspace (maximum 64 KiB)."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response

  schema do
    field :path, :string, required: true, description: "Relative workspace file path"
  end

  @impl true
  def execute(%{path: path}, frame) do
    result = McpRunner.Operations.read_file(path)
    {:reply, to_response(result), frame}
  end

  defp to_response({:ok, data}), do: Response.json(Response.tool(), data)
  defp to_response({:error, reason}), do: Response.error(Response.tool(), reason)
end
