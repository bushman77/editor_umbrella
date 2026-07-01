defmodule Editor.Workspaces do
  @moduledoc """
  Reads and resolves configured editor workspaces.

  This module is intentionally pure/config-backed for now. It gives the web
  layer a stable project identity instead of deriving the editor root from the
  process current directory.
  """

  alias Editor.Workspace

  @spec list() :: [Workspace.t()]
  def list do
    :editor
    |> Application.get_env(:workspaces, [])
    |> normalize_configured_workspaces()
    |> ensure_fallback_workspace()
    |> Enum.uniq_by(& &1.id)
  end

  @spec default() :: Workspace.t()
  def default do
    List.first(list())
  end

  @spec resolve(String.t() | nil) :: {:ok, Workspace.t()} | {:error, :not_found}
  def resolve(nil), do: {:ok, default()}
  def resolve(""), do: {:ok, default()}

  def resolve(id) when is_binary(id) do
    normalized_id = normalize_id(id)

    case Enum.find(list(), &(&1.id == normalized_id)) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end

  @spec resolve!(String.t() | nil) :: Workspace.t()
  def resolve!(id) do
    case resolve(id) do
      {:ok, workspace} -> workspace
      {:error, :not_found} -> default()
    end
  end

  defp normalize_configured_workspaces(configured) when is_list(configured) do
    configured
    |> Enum.flat_map(fn attrs ->
      case Workspace.new(attrs) do
        {:ok, workspace} -> [workspace]
        {:error, _reason} -> []
      end
    end)
  end

  defp normalize_configured_workspaces(_configured), do: []

  defp ensure_fallback_workspace([]) do
    [
      Workspace.new!(
        id: "current",
        name: "Current Directory",
        root: File.cwd!()
      )
    ]
  end

  defp ensure_fallback_workspace(workspaces), do: workspaces

  defp normalize_id(id) do
    id
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end
end
