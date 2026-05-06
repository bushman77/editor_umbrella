defmodule EditorWeb.PageController do
  use EditorWeb, :controller

  @spec home(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def home(conn, _params) do
    cwd = File.cwd!()

    entries =
      cwd
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(fn name ->
        path = Path.join(cwd, name)
        stat = File.stat!(path)

        %{
          name: name,
          path: path,
          type: stat.type
        }
      end)

    render(conn, :home, cwd: cwd, entries: entries)
  end
end
