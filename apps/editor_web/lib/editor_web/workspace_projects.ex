# apps/editor_web/lib/editor_web/workspace_projects.ex
defmodule EditorWeb.WorkspaceProjects do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2, update: 3]
  alias Editor.Workspaces

  @spec assign_defaults(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_defaults(socket) do
    socket
    |> assign(:projects, Workspaces.list_projects())
    |> assign(
      :project_form,
      to_form(%{"name" => "", "git_url" => "", "branch" => "main"}, as: :project)
    )
    |> assign(:syncing_project_ids, MapSet.new())
    |> assign(:project_error, nil)
    |> assign(:project_success, nil)
  end

  @spec refresh_projects(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_projects(socket) do
    assign(socket, :projects, Workspaces.list_projects())
  end

  @spec prepare_create(map()) :: {:ok, map()} | {:error, keyword()}
  def prepare_create(params) do
    name = String.trim(params["name"] || "")
    git_url = String.trim(params["git_url"] || "")
    branch = String.trim(params["branch"] || "main")

    cond do
      name == "" ->
        {:error, [project_error: "Enter a project name."]}

      git_url == "" ->
        {:error, [project_error: "Enter a git URL."]}

      true ->
        {:ok, %{name: name, git_url: git_url, branch: branch, type: :git}}
    end
  end

  @spec handle_create_success(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def handle_create_success(socket, _project) do
    socket
    |> refresh_projects()
    |> assign(
      :project_form,
      to_form(%{"name" => "", "git_url" => "", "branch" => "main"}, as: :project)
    )
    |> assign(:project_error, nil)
    |> assign(:project_success, "Project added. Click Sync to clone it.")
  end

  @spec handle_create_failure(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_create_failure(socket, changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    message =
      errors
      |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
      |> Enum.join("; ")

    assign(socket, :project_error, message || "Could not create project.")
  end

  @spec mark_syncing(Phoenix.LiveView.Socket.t(), pos_integer()) ::
          Phoenix.LiveView.Socket.t()
  def mark_syncing(socket, project_id) do
    update(socket, :syncing_project_ids, &MapSet.put(&1, project_id))
  end

  @spec clear_syncing(Phoenix.LiveView.Socket.t(), pos_integer()) ::
          Phoenix.LiveView.Socket.t()
  def clear_syncing(socket, project_id) do
    update(socket, :syncing_project_ids, &MapSet.delete(&1, project_id))
  end

  @spec syncing?(map(), pos_integer()) :: boolean()
  def syncing?(assigns, project_id) do
    MapSet.member?(assigns[:syncing_project_ids] || MapSet.new(), project_id)
  end

  @spec sync_status_label(Editor.Workspaces.Project.t()) :: String.t()
  def sync_status_label(project) do
    cond do
      project.last_sync_status == "ok" ->
        "Synced #{format_time(project.last_synced_at)}"

      project.last_sync_status == "error" ->
        "Sync failed: #{truncate_error(project.last_sync_error)}"

      true ->
        "Not synced yet"
    end
  end

  @spec cloned?(Editor.Workspaces.Project.t()) :: boolean()
  def cloned?(project) do
    Editor.Workspaces.Git.cloned?(project)
  end

  defp format_time(nil), do: "never"
  defp format_time(datetime), do: Calendar.strftime(datetime, "%b %d, %H:%M")

  defp truncate_error(nil), do: "unknown"

  defp truncate_error(error) when is_binary(error) do
    if String.length(error) > 60 do
      String.slice(error, 0, 60) <> "..."
    else
      error
    end
  end
end
