defmodule Llm.ProjectMemory.Builder do
  @moduledoc """
  Builds project-memory snapshots from files on disk.

  This is intentionally deterministic and local. It reads files, extracts cheap
  structural metadata, chunks content, and returns an in-memory
  `Llm.ProjectMemory` snapshot that later prompt builders can select from.
  """

  alias Llm.ProjectMemory
  alias Llm.ProjectMemory.FileChunk
  alias Llm.ProjectMemory.FileSummary
  alias Llm.Prompts

  @default_max_files 200
  @default_chunk_lines 120
  @default_chunk_overlap 20

  @type build_opts :: [
          project_id: String.t(),
          max_files: pos_integer(),
          chunk_lines: pos_integer(),
          chunk_overlap: non_neg_integer()
        ]

  @type file_memory_result :: %{
          summary: FileSummary.t(),
          chunks: [FileChunk.t()]
        }

  @spec build(String.t(), build_opts()) :: {:ok, ProjectMemory.snapshot()} | {:error, String.t()}
  def build(root_path, opts \\ []) when is_binary(root_path) and is_list(opts) do
    expanded_root = Path.expand(root_path)

    if File.dir?(expanded_root) do
      snapshot =
        expanded_root
        |> file_paths(opts)
        |> build_files(expanded_root, opts)
        |> Enum.reduce(ProjectMemory.new_snapshot(project_id: project_id(expanded_root, opts)), fn
          {:ok, %{summary: summary, chunks: chunks}}, acc ->
            acc
            |> ProjectMemory.put_file_summary(summary)
            |> ProjectMemory.put_file_chunks(chunks)

          {:error, _reason}, acc ->
            acc
        end)

      {:ok, snapshot}
    else
      {:error, "Root path is not a directory: #{expanded_root}"}
    end
  end

  @spec build_file(String.t(), String.t(), build_opts()) ::
          {:ok, file_memory_result()} | {:error, String.t()}
  def build_file(root_path, file_path, opts \\ [])
      when is_binary(root_path) and is_binary(file_path) and is_list(opts) do
    expanded_root = Path.expand(root_path)
    expanded_path = Path.expand(file_path)

    with :ok <- ensure_within_root(expanded_path, expanded_root),
         true <- Prompts.wanted_file?(expanded_path),
         {:ok, content} <- File.read(expanded_path) do
      relative_path = Path.relative_to(expanded_path, expanded_root)
      language = FileSummary.infer_language(relative_path)
      analysis = analyze_content(content, language)
      file_hash = sha256(content)

      summary =
        FileSummary.new(
          path: relative_path,
          language: language,
          sha256: file_hash,
          summary: summarize_file(relative_path, analysis),
          symbols: analysis.public_functions,
          module_names: analysis.defined_modules,
          last_seen_at: DateTime.utc_now(),
          metadata: %{
            byte_size: byte_size(content),
            line_count: line_count(content)
          }
        )

      chunks =
        content
        |> chunk_content(relative_path, opts)
        |> Enum.map(fn chunk ->
          %{
            chunk
            | file_id: file_hash,
              module_names: modules_for_chunk(chunk.content, analysis.defined_modules),
              symbols: symbols_for_chunk(chunk.content, analysis.public_functions)
          }
        end)

      {:ok, %{summary: summary, chunks: chunks}}
    else
      false -> {:error, "Unsupported file type: #{expanded_path}"}
      {:error, reason} -> {:error, format_file_error(expanded_path, reason)}
    end
  end

  defp file_paths(root_path, opts) do
    root_path
    |> Prompts.list_files_recursive()
    |> Enum.filter(&Prompts.wanted_file?/1)
    |> Enum.take(Keyword.get(opts, :max_files, @default_max_files))
  end

  defp build_files(paths, root_path, opts) do
    paths
    |> Task.async_stream(&build_file(root_path, &1, opts), timeout: :infinity)
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, inspect(reason)}
    end)
  end

  defp chunk_content(content, path, opts) do
    chunk_lines = Keyword.get(opts, :chunk_lines, @default_chunk_lines)
    overlap = Keyword.get(opts, :chunk_overlap, @default_chunk_overlap)
    step = max(chunk_lines - overlap, 1)

    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.chunk_every(chunk_lines, step, [])
    |> Enum.with_index()
    |> Enum.map(fn {indexed_lines, chunk_index} ->
      lines = Enum.map(indexed_lines, fn {line, _line_number} -> line end)
      {_first_line, start_line} = List.first(indexed_lines)
      {_last_line, end_line} = List.last(indexed_lines)

      FileChunk.from_lines(path, lines, chunk_index,
        id: "#{path}:#{chunk_index}",
        start_line: start_line,
        end_line: end_line,
        summary: summarize_chunk(path, start_line, end_line, lines)
      )
    end)
  end

  defp analyze_content(content, language) when language in ["elixir", "heex"] do
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        {_ast, acc} =
          Macro.prewalk(
            ast,
            %{defined_modules: [], referenced_modules: [], public_functions: []},
            fn
              {:defmodule, _, [{:__aliases__, _, parts}, _block]} = node, acc ->
                {node, update_in(acc.defined_modules, &[Enum.join(parts, ".") | &1])}

              {:alias, _, args} = node, acc ->
                {node, update_in(acc.referenced_modules, &(extract_aliases(args) ++ &1))}

              {:use, _, args} = node, acc ->
                {node, update_in(acc.referenced_modules, &(extract_module_refs(args) ++ &1))}

              {:import, _, args} = node, acc ->
                {node, update_in(acc.referenced_modules, &(extract_module_refs(args) ++ &1))}

              {:require, _, args} = node, acc ->
                {node, update_in(acc.referenced_modules, &(extract_module_refs(args) ++ &1))}

              {:def, _, [{name, _, _args}, _body]} = node, acc when is_atom(name) ->
                {node, update_in(acc.public_functions, &[Atom.to_string(name) | &1])}

              node, acc ->
                {node, acc}
            end
          )

        %{
          defined_modules: Enum.uniq(acc.defined_modules),
          referenced_modules: Enum.uniq(acc.referenced_modules),
          public_functions: Enum.uniq(acc.public_functions)
        }

      {:error, _reason} ->
        %{defined_modules: [], referenced_modules: [], public_functions: []}
    end
  end

  defp analyze_content(_content, _language) do
    %{defined_modules: [], referenced_modules: [], public_functions: []}
  end

  defp summarize_file(path, analysis) do
    modules = Enum.take(analysis.defined_modules, 3)
    functions = Enum.take(analysis.public_functions, 6)

    cond do
      modules != [] and functions != [] ->
        "Defines #{Enum.join(modules, ", ")} with public functions #{Enum.join(functions, ", ")}."

      modules != [] ->
        "Defines #{Enum.join(modules, ", ")}."

      functions != [] ->
        "Contains public functions #{Enum.join(functions, ", ")}."

      true ->
        "#{path} project file."
    end
  end

  defp summarize_chunk(path, start_line, end_line, lines) do
    heading =
      lines
      |> Enum.find(fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, ["defmodule ", "def ", "defp ", "defmacro "])
      end)

    case heading do
      nil -> "#{path}:#{start_line}-#{end_line}"
      line -> "#{path}:#{start_line}-#{end_line} around #{String.trim(line)}"
    end
  end

  defp modules_for_chunk(content, module_names) do
    Enum.filter(module_names, &String.contains?(content, &1))
  end

  defp symbols_for_chunk(content, symbols) do
    Enum.filter(symbols, fn symbol ->
      String.contains?(content, "def #{symbol}") or String.contains?(content, "#{symbol}(")
    end)
  end

  defp extract_aliases(args) do
    args
    |> List.wrap()
    |> Enum.flat_map(&extract_module_refs/1)
  end

  defp extract_module_refs({:__aliases__, _, parts}), do: [Enum.join(parts, ".")]

  defp extract_module_refs({:., _, [{:__aliases__, _, parts}, _name]}),
    do: [Enum.join(parts, ".")]

  defp extract_module_refs(list) when is_list(list) do
    Enum.flat_map(list, &extract_module_refs/1)
  end

  defp extract_module_refs(_other), do: []

  defp ensure_within_root(path, root_path) do
    relative = Path.relative_to(path, root_path)

    if String.starts_with?(relative, "..") do
      {:error, "File is outside project root: #{path}"}
    else
      :ok
    end
  end

  defp project_id(root_path, opts) do
    Keyword.get(opts, :project_id, Path.basename(root_path))
  end

  defp line_count(content) do
    content
    |> String.split("\n")
    |> length()
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  defp format_file_error(path, reason) when is_atom(reason),
    do: "#{path}: #{:file.format_error(reason)}"

  defp format_file_error(path, reason), do: "#{path}: #{inspect(reason)}"
end
