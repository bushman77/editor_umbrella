defmodule McpRunner.Policy do
  @moduledoc """
  Workspace boundary for local MCP tools.

  The workspace comes only from the process environment, never MCP arguments.
  Existing path components must not be symbolic links. This is defense in
  depth, not a sandbox against a concurrently hostile local process.
  """

  @blocked_segments ~w(.git .ssh .aws .config .qwen node_modules _build deps)
  @blocked_names ~w(.env .env.local .env.production .env.development credentials credentials.json)

  @spec root() :: {:ok, String.t()} | {:error, String.t()}
  def root do
    case System.get_env("EDITOR_MCP_WORKSPACE_ROOT") do
      nil ->
        {:error, "EDITOR_MCP_WORKSPACE_ROOT is not set"}

      raw when is_binary(raw) ->
        cond do
          Path.type(raw) != :absolute ->
            {:error, "Workspace root must be an absolute path"}

          Path.expand(raw) == "/" ->
            {:error, "Filesystem root is not an allowed workspace"}

          true ->
            expanded = Path.expand(raw)

            with :ok <- no_symlink_ancestors(expanded),
                 true <- File.dir?(expanded) do
              {:ok, expanded}
            else
              false -> {:error, "Workspace root is not a directory"}
              {:error, _} = error -> error
            end
        end
    end
  end

  @spec existing_path(String.t(), :file | :directory) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  def existing_path(relative_path, kind) when is_binary(relative_path) do
    with {:ok, root} <- root(),
         :ok <- validate_relative_path(relative_path),
         candidate <- Path.expand(relative_path, root),
         :ok <- within_root(candidate, root),
         :ok <- no_symlink_ancestors(candidate),
         :ok <- valid_kind(candidate, kind) do
      {:ok, root, candidate}
    end
  end

  @spec execution_allowed?() :: boolean()
  def execution_allowed?, do: System.get_env("EDITOR_MCP_ALLOW_EXECUTION") == "1"

  defp validate_relative_path(path) do
    segments = Path.split(path)
    name = Path.basename(path)

    cond do
      Path.type(path) != :relative ->
        {:error, "Tool paths must be relative to the configured workspace"}

      Enum.any?(segments, &(&1 in @blocked_segments)) ->
        {:error, "Access to generated, private, or dependency directories is disabled"}

      name in @blocked_names or String.starts_with?(name, ".env.") or
          String.ends_with?(name, [".pem", ".key", ".p12", ".pfx"]) ->
        {:error, "Access to credential and key files is disabled"}

      true ->
        :ok
    end
  end

  defp within_root(candidate, root) do
    if candidate == root or String.starts_with?(candidate, root <> "/") do
      :ok
    else
      {:error, "Requested path is outside the configured workspace"}
    end
  end

  defp no_symlink_ancestors(path) do
    path
    |> ancestor_paths()
    |> Enum.reduce_while(:ok, fn entry, _acc ->
      case File.lstat(entry) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, "Symbolic links are not allowed in MCP paths"}}

        {:ok, _} ->
          {:cont, :ok}

        {:error, _} ->
          {:halt, {:error, "Path does not exist or cannot be inspected"}}
      end
    end)
  end

  defp ancestor_paths(path) do
    Stream.unfold(path, fn
      nil -> nil
      "/" -> {"/", nil}
      current -> {current, Path.dirname(current)}
    end)
  end

  defp valid_kind(path, :file) do
    if File.regular?(path), do: :ok, else: {:error, "Not a regular file"}
  end

  defp valid_kind(path, :directory) do
    if File.dir?(path), do: :ok, else: {:error, "Not a directory"}
  end
end
