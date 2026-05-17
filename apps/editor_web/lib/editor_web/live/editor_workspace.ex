defmodule EditorWeb.EditorWorkspace do
  @moduledoc false

  @type entry :: %{
          name: String.t(),
          path: String.t(),
          type: atom(),
          dom_id: String.t(),
          expanded?: boolean(),
          children: [entry()]
        }

  @spec toggle_directory([entry()], String.t(), String.t()) ::
          {:ok, [entry()]} | {:error, String.t()}
  def toggle_directory(entries, path, workspace_root) do
    do_toggle_directory(entries, path, workspace_root)
  end

  @spec load_entries(String.t(), String.t()) :: [entry()]
  def load_entries(path, workspace_root) do
    case load_entries_result(path, workspace_root) do
      {:ok, entries} -> entries
      {:error, _message} -> []
    end
  end

  @spec load_entries_result(String.t(), String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def load_entries_result(path, workspace_root) do
    with {:ok, path} <- ensure_workspace_directory(path, workspace_root),
         {:ok, names} <- File.ls(path) do
      entries =
        names
        |> Enum.reduce([], fn name, acc ->
          full_path = Path.join(path, name)

          case File.stat(full_path) do
            {:ok, stat} ->
              [entry_from_stat(name, full_path, stat.type) | acc]

            {:error, _reason} ->
              acc
          end
        end)
        |> Enum.sort_by(fn entry ->
          {entry.type != :directory, String.downcase(entry.name)}
        end)

      {:ok, entries}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        {:error, "Could not read directory: #{:file.format_error(reason)}"}
    end
  end

  @spec normalize_path(String.t() | nil, String.t()) :: String.t()
  def normalize_path(path, current_path) when is_nil(path), do: current_path

  def normalize_path(path, current_path) do
    trimmed =
      path
      |> String.trim()
      |> String.replace("\\", "/")

    cond do
      trimmed == "" ->
        current_path

      trimmed == "~" or String.starts_with?(trimmed, "~/") ->
        Path.expand(trimmed)

      Path.type(trimmed) == :absolute ->
        Path.expand(trimmed)

      true ->
        Path.expand(trimmed, current_path)
    end
  end

  @spec validate_cwd(String.t(), String.t(), String.t()) :: String.t()
  def validate_cwd(path, default_cwd, workspace_root) do
    case ensure_workspace_directory(path, workspace_root) do
      {:ok, validated_path} -> validated_path
      {:error, _message} -> default_cwd
    end
  end

  @spec context_folder?(String.t(), String.t()) :: boolean()
  def context_folder?(path, workspace_root) do
    File.dir?(path) and path_within_root?(path, workspace_root)
  end

  @spec context_file?(String.t(), String.t()) :: boolean()
  def context_file?(path, workspace_root) do
    File.regular?(path) and path_within_root?(path, workspace_root)
  end

  @spec child_path(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def child_path(parent_path, name) do
    trimmed_name = String.trim(name || "")

    if valid_child_name?(trimmed_name) do
      {:ok, Path.expand(trimmed_name, parent_path)}
    else
      {:error, "Use a file or folder name without slashes."}
    end
  end

  @spec sibling_path(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def sibling_path(path, name), do: child_path(Path.dirname(path), name)

  @spec ensure_not_root_folder(String.t(), String.t()) :: :ok | {:error, String.t()}
  def ensure_not_root_folder(path, workspace_root) do
    if Path.expand(path) == Path.expand(workspace_root) do
      {:error, "The current workspace root cannot be deleted from the context menu."}
    else
      :ok
    end
  end

  @spec path_within_root?(String.t(), String.t()) :: boolean()
  def path_within_root?(path, root_path) do
    relative_path = Path.relative_to(Path.expand(path), Path.expand(root_path))
    relative_path == "." or not String.starts_with?(relative_path, "..")
  end

  @spec matching_file_paths(String.t(), String.t()) :: [String.t()]
  def matching_file_paths(search_root, pattern) do
    case System.cmd("rg", ["-l", "--fixed-strings", pattern, search_root], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&File.regular?/1)
        |> Enum.take(12)

      {_output, _status} ->
        []
    end
  end

  @spec related_search_root(String.t(), String.t(), String.t()) :: String.t()
  def related_search_root(cwd, selected_path, workspace_root) do
    candidate_root =
      umbrella_root_for_path(cwd) ||
        umbrella_root_for_path(selected_path) ||
        Path.expand(cwd)

    clamp_to_workspace(candidate_root, workspace_root)
  end

  @spec ensure_workspace_directory(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def ensure_workspace_directory(path, workspace_root) do
    with {:ok, path} <- ensure_within_workspace(path, workspace_root),
         true <- File.dir?(path) or {:error, "Not a directory: #{path}"} do
      {:ok, path}
    end
  end

  @spec ensure_workspace_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure_workspace_file(path, workspace_root) do
    with {:ok, path} <- ensure_within_workspace(path, workspace_root),
         true <- File.regular?(path) or {:error, "Not a file: #{path}"} do
      {:ok, path}
    end
  end

  @spec ensure_within_workspace(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def ensure_within_workspace(path, workspace_root)
      when is_binary(path) and is_binary(workspace_root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(workspace_root)

    if path_within_root?(expanded_path, expanded_root) do
      {:ok, expanded_path}
    else
      {:error, "Path is outside the workspace root."}
    end
  end

  defp do_toggle_directory(entries, path, workspace_root) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      cond do
        entry.type == :directory and entry.path == path ->
          case toggle_entry(entry, workspace_root) do
            {:ok, updated_entry} ->
              {:cont, {:ok, [updated_entry | acc]}}

            {:error, message} ->
              {:halt, {:error, message}}
          end

        entry.type == :directory ->
          case do_toggle_directory(entry.children, path, workspace_root) do
            {:ok, children} ->
              {:cont, {:ok, [%{entry | children: children} | acc]}}

            {:error, message} ->
              {:halt, {:error, message}}
          end

        true ->
          {:cont, {:ok, [entry | acc]}}
      end
    end)
    |> case do
      {:ok, updated_entries} -> {:ok, Enum.reverse(updated_entries)}
      {:error, message} -> {:error, message}
    end
  end

  defp toggle_entry(entry, workspace_root) do
    if entry.expanded? do
      {:ok, %{entry | expanded?: false}}
    else
      case load_entries_result(entry.path, workspace_root) do
        {:ok, children} ->
          {:ok, %{entry | expanded?: true, children: children}}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp entry_from_stat(name, full_path, type) do
    %{
      name: name,
      path: full_path,
      type: type,
      dom_id: Base.url_encode64(full_path, padding: false),
      expanded?: false,
      children: []
    }
  end

  defp valid_child_name?(name) do
    name != "" and name not in [".", ".."] and not String.contains?(name, ["/", "\\"])
  end

  defp umbrella_root_for_path(path) do
    expanded_path = Path.expand(path)
    parent_path = Path.dirname(expanded_path)

    cond do
      parent_path == expanded_path ->
        nil

      Path.basename(parent_path) == "apps" and
          File.exists?(Path.join(Path.dirname(parent_path), "mix.exs")) ->
        Path.dirname(parent_path)

      true ->
        umbrella_root_for_path(parent_path)
    end
  end

  defp clamp_to_workspace(path, workspace_root) do
    case ensure_within_workspace(path, workspace_root) do
      {:ok, safe_path} -> safe_path
      {:error, _message} -> Path.expand(workspace_root)
    end
  end
end
