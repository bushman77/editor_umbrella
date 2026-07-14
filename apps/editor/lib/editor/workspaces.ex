# apps/editor/lib/editor/workspaces.ex
defmodule Editor.Workspaces do
  @moduledoc """
  Reads and resolves configured editor workspaces.

  Workspaces are now database-backed git project records. A fallback
  workspace pointing at the current directory is provided when no
  projects have been registered yet.
  """

  alias Editor.Repo
  alias Editor.Workspace
  alias Editor.Workspaces.Project

  import Ecto.Query

  @spec list() :: [Workspace.t()]
  def list do
    case Repo.all(from p in Project, order_by: p.name) do
      [] -> fallback_workspaces()
      projects -> Enum.map(projects, &project_to_workspace/1)
    end
  end

  @spec default() :: Workspace.t()
  def default do
    List.first(list())
  end

  @spec resolve(String.t() | nil) :: {:ok, Workspace.t()} | {:error, :not_found}
  def resolve(nil), do: {:ok, default()}
  def resolve(""), do: {:ok, default()}

  def resolve(id) when is_binary(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project_to_workspace(project)}
    end
  end

  @spec resolve!(String.t() | nil) :: Workspace.t()
  def resolve!(id) do
    case resolve(id) do
      {:ok, workspace} -> workspace
      {:error, :not_found} -> default()
    end
  end

  @spec list_projects() :: [Project.t()]
  def list_projects do
    Repo.all(from p in Project, order_by: p.name)
  end

  @spec get_project(String.t() | pos_integer()) :: Project.t() | nil
  def get_project(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> Repo.get(Project, int_id)
      _ -> nil
    end
  end

  def get_project(id) when is_integer(id), do: Repo.get(Project, id)

  @spec create_project(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @spec delete_project(String.t() | pos_integer()) ::
          {:ok, Project.t()} | {:error, :not_found | term()}
  def delete_project(id) do
    case get_project(id) do
      nil -> {:error, :not_found}
      project -> Repo.delete(project)
    end
  end

  defp project_to_workspace(%Project{} = project) do
    {:ok, workspace} =
      Workspace.new(%{
        id: Integer.to_string(project.id),
        name: project.name,
        root: project.local_path
      })

    workspace
  end

  defp fallback_workspaces do
    [
      Workspace.new!(
        id: "current",
        name: "Current Directory",
        root: File.cwd!()
      )
    ]
  end
end
