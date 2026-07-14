# apps/editor/lib/editor/workspaces/sync.ex
defmodule Editor.Workspaces.Sync do
  @moduledoc """
  Orchestrates workspace repository synchronization.

  Decides whether to clone or pull based on whether the local path
  already contains a git repository, and updates the project record
  with sync results.
  """

  alias Editor.Repo
  alias Editor.Workspaces.Git
  alias Editor.Workspaces.Project

  @spec run(Project.t()) :: {:ok, Project.t(), map()} | {:error, Project.t(), term()}
  def run(%Project{} = project) do
    result = do_sync(project)
    update_project_from_result(project, result)
  end

  defp do_sync(project) do
    if Git.cloned?(project) do
      Git.pull(project)
    else
      Git.clone(project)
    end
  end

  defp update_project_from_result(project, {:ok, info}) do
    {:ok, updated} =
      project
      |> Project.sync_changeset(%{
        last_synced_at: DateTime.utc_now(),
        last_sync_status: "ok",
        last_sync_error: nil
      })
      |> Repo.update()

    {:ok, updated, info}
  end

  defp update_project_from_result(project, {:error, reason}) do
    {:ok, updated} =
      project
      |> Project.sync_changeset(%{
        last_synced_at: DateTime.utc_now(),
        last_sync_status: "error",
        last_sync_error: format_error(reason)
      })
      |> Repo.update()

    {:error, updated, reason}
  end

  defp format_error({:clone_failed, status, output}), do: "clone failed (exit #{status}): #{output}"
  defp format_error({:pull_failed, status, output}), do: "pull failed (exit #{status}): #{output}"
  defp format_error({:git_error, status, output}), do: "git error (exit #{status}): #{output}"
  defp format_error(:timeout), do: "operation timed out"
  defp format_error({:directory_not_empty, path}), do: "directory not empty: #{path}"
  defp format_error({:git_command_failed, message}), do: message
  defp format_error(reason), do: inspect(reason)
end
