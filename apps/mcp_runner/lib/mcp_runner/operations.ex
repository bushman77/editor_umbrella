defmodule McpRunner.Operations do
  @moduledoc """
  Narrow, non-shell developer operations for the MCP transport.

  No caller-supplied executable, working directory, environment, or command-line
  argument vector is accepted. Mix commands are separately opted in.
  """

  alias McpRunner.CommandRunner
  alias McpRunner.Policy

  @max_read_bytes 65_536
  @max_list_entries 200

  @type result :: {:ok, map()} | {:error, String.t()}

  @spec read_file(String.t()) :: result()
  def read_file(path) do
    with {:ok, root, absolute_path} <- Policy.existing_path(path, :file),
         {:ok, io} <- File.open(absolute_path, [:read, :binary]) do
      try do
        case IO.binread(io, @max_read_bytes + 1) do
          {:error, reason} ->
            {:error, "File read failed: #{inspect(reason)}"}

          :eof ->
            {:ok, %{path: Path.relative_to(absolute_path, root), content: "", truncated: false}}

          data when is_binary(data) ->
            content = binary_part(data, 0, min(byte_size(data), @max_read_bytes))

            if String.valid?(content) do
              {:ok,
               %{
                 path: Path.relative_to(absolute_path, root),
                 content: content,
                 truncated: byte_size(data) > @max_read_bytes
               }}
            else
              {:error, "File content is not valid UTF-8 (or truncation split a character)"}
            end
        end
      after
        File.close(io)
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, "File open failed: #{inspect(reason)}"}
      {:error, _} = error -> error
    end
  end

  @spec list_files(String.t()) :: result()
  def list_files(path) do
    with {:ok, root, absolute_path} <- Policy.existing_path(path, :directory),
         {:ok, names} <- File.ls(absolute_path) do
      entries =
        names
        |> Enum.sort()
        |> Enum.take(@max_list_entries)
        |> Enum.flat_map(fn name ->
          candidate = Path.join(absolute_path, name)

          case File.lstat(candidate) do
            {:ok, %File.Stat{type: type}} when type in [:regular, :directory] ->
              case Policy.existing_path(Path.relative_to(candidate, root), type_to_kind(type)) do
                {:ok, _, _} -> [%{name: name, type: type}]
                {:error, _} -> []
              end

            _ ->
              []
          end
        end)

      {:ok,
       %{
         directory: Path.relative_to(absolute_path, root),
         entries: entries,
         truncated: length(names) > @max_list_entries
       }}
    end
  end

  @spec git_status() :: result()
  def git_status do
    with {:ok, root} <- Policy.root(),
         {:ok, result} <- CommandRunner.run("git", ["status", "--short", "--branch"], root, 10) do
      {:ok, result}
    end
  end

  @spec compile() :: result()
  def compile do
    run_mix("compile", [], 60)
  end

  @spec run_tests(String.t() | nil) :: result()
  def run_tests(path \\ nil) do
    with {:ok, args} <- test_args(path) do
      run_mix("test", args, 120)
    end
  end

  defp test_args(nil), do: {:ok, []}
  defp test_args(""), do: {:ok, []}

  defp test_args(path) when is_binary(path) do
    with true <- String.ends_with?(path, "_test.exs") or {:error, "Only *_test.exs files are allowed"},
         {:ok, root, absolute_path} <- Policy.existing_path(path, :file) do
      {:ok, [Path.relative_to(absolute_path, root)]}
    end
  end

  defp run_mix(task, args, seconds) do
    with true <- Policy.execution_allowed?() or {:error, "Mix execution is disabled; set EDITOR_MCP_ALLOW_EXECUTION=1 locally"},
         {:ok, root} <- Policy.root(),
         true <- File.regular?(Path.join(root, "mix.exs")) or {:error, "Workspace is not a Mix project"},
         {:ok, result} <- CommandRunner.run("mix", [task | args], root, seconds) do
      {:ok, Map.merge(result, %{command: "mix #{task}", arguments: args})}
    end
  end

  defp type_to_kind(:regular), do: :file
  defp type_to_kind(:directory), do: :directory
end
