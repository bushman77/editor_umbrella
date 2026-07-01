defmodule Editor.Workspace do
  @moduledoc """
  Data structure for a project/workspace the editor is allowed to open.

  A workspace is the durable boundary for file operations, project memory,
  conversations, and OpenCode sessions. File browsing can move within the root,
  but path helpers in `EditorWeb.EditorWorkspace` should keep every operation
  clamped to `root`.
  """

  @enforce_keys [:id, :name, :root]
  defstruct [:id, :name, :root]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          root: String.t()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, id} <- required_string(attrs, :id),
         {:ok, name} <- required_string(attrs, :name),
         {:ok, root} <- required_string(attrs, :root) do
      {:ok,
       %__MODULE__{
         id: normalize_id(id),
         name: String.trim(name),
         root: root |> Path.expand() |> Path.absname()
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, workspace} -> workspace
      {:error, reason} -> raise ArgumentError, "invalid workspace: #{inspect(reason)}"
    end
  end

  defp required_string(attrs, key) do
    value = Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

    case value do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error, {:blank, key}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:missing, key}}
    end
  end

  defp normalize_id(id) do
    id
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "workspace"
      normalized -> normalized
    end
  end
end
