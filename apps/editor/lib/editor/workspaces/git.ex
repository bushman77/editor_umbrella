# apps/editor/lib/editor/workspaces/git.ex
defmodule Editor.Workspaces.Git do
  @moduledoc """
  Git operations for workspace project repositories.

  All operations run in async tasks with timeouts so they don't block callers.
  """

  @default_timeout 120_000

  @type project :: Editor.Workspaces.Project.t()

  @spec clone(project(), keyword()) :: {:ok, map()} | {:error, term()}
  def clone(project, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    File.mkdir_p!(Path.dirname(project.local_path))

    if File.dir?(project.local_path) and dir_not_empty?(project.local_path) do
      {:error, {:directory_not_empty, project.local_path}}
    else
      args = ["clone", project.git_url, project.local_path, "--branch", project.branch]

      case run_git(args, cwd: Path.dirname(project.local_path), timeout: timeout) do
        {:ok, output, 0} ->
          {:ok, %{output: String.trim(output), branch: project.branch}}
        {:ok, output, status} ->
          {:error, {:clone_failed, status, String.trim(output)}}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec pull(project(), keyword()) :: {:ok, map()} | {:error, term()}
  def pull(project, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case run_git(["pull", "origin", project.branch], cwd: project.local_path, timeout: timeout) do
      {:ok, output, 0} ->
        {:ok, %{output: String.trim(output), branch: project.branch}}
      {:ok, output, status} ->
        {:error, {:pull_failed, status, String.trim(output)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec status(project()) :: {:ok, map()} | {:error, term()}
  def status(project) do
    with {:ok, branch_out, 0} <- run_git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: project.local_path),
         {:ok, dirty_out, 0} <- run_git(["status", "--porcelain"], cwd: project.local_path) do
      {:ok, %{
        branch: String.trim(branch_out),
        dirty?: String.trim(dirty_out) != "",
        dirty_files: parse_dirty_files(dirty_out)
      }}
    else
      {:ok, output, status} -> {:error, {:git_error, status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cloned?(project()) :: boolean()
  def cloned?(project) do
    git_dir = Path.join(project.local_path, ".git")
    File.dir?(git_dir) or File.regular?(git_dir)
  end

  # --- Private ---

  defp run_git(args, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.async(fn ->
      System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> {:ok, output, status}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:task_exit, inspect(reason)}}
    end
  rescue
    error -> {:error, {:git_command_failed, Exception.message(error)}}
  end

  defp dir_not_empty?(path) do
    case File.ls(path) do
      {:ok, []} -> false
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp parse_dirty_files(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case line do
        <<status::binary-size(2), " ", path::binary>> ->
          %{status: String.trim(status), path: path}
        path ->
          %{status: "??", path: path}
      end
    end)
  end
end
