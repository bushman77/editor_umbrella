defmodule Llm.ContextBuilder do
  @moduledoc """
  Selects file and folder context for LLM requests.
  """

  alias Llm.Prompts

  @max_folder_files 24
  @max_related_files 10
  @primary_file_max_chars 250_000
  @supporting_file_max_chars 6_000
  @folder_file_max_chars 6_000
  @max_total_chars 300_000
  @allowed_extensions [".ex", ".exs", ".heex", ".js", ".ts", ".tsx", ".json", ".md"]

  @type prompt_file :: %{path: String.t(), content: String.t()}
  @type context_mode :: :file | :files | :folder
  @type analysis :: %{
          defined_modules: [String.t()],
          referenced_modules: [String.t()],
          public_functions: [atom()]
        }
  @type context :: %{
          mode: context_mode(),
          root_path: String.t(),
          question: String.t(),
          primary_path: String.t() | nil,
          files: [prompt_file()],
          messages: Prompts.messages()
        }

  @spec build(String.t(), String.t() | nil, String.t()) :: {:ok, context()} | {:error, String.t()}
  def build(root_path, selected_file, question)
      when is_binary(root_path) and is_binary(question) do
    trimmed_question = String.trim(question)
    expanded_root = Path.expand(root_path)

    cond do
      trimmed_question == "" ->
        {:error, "Question cannot be empty."}

      not File.dir?(expanded_root) ->
        {:error, "Root path is not a directory: #{expanded_root}"}

      is_binary(selected_file) and File.regular?(selected_file) ->
        build_for_file(expanded_root, Path.expand(selected_file), trimmed_question)

      true ->
        build_for_folder(expanded_root, trimmed_question)
    end
  end

  @spec build_for_file(String.t(), String.t(), String.t()) ::
          {:ok, context()} | {:error, String.t()}
  def build_for_file(root_path, file_path, question)
      when is_binary(root_path) and is_binary(file_path) and is_binary(question) do
    with :ok <- ensure_within_root(file_path, root_path),
         {:ok, primary_file} <- read_prompt_file(file_path, @primary_file_max_chars) do
      related_files =
        file_path
        |> related_file_paths_for_refactor(primary_file.content, question, root_path)
        |> Enum.reject(&(&1 == primary_file.path))
        |> Enum.take(@max_related_files - 1)
        |> Enum.map(&read_prompt_file(&1, @supporting_file_max_chars))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, file} -> file end)

      files =
        [primary_file | related_files]
        |> trim_files_to_total_budget(@max_total_chars)

      {:ok,
       %{
         mode: context_mode(files),
         root_path: root_path,
         question: question,
         primary_path: primary_file.path,
         files: files,
         messages: build_messages(files, root_path, question, primary_file.path)
       }}
    end
  end

  @spec build_for_folder(String.t(), String.t()) :: {:ok, context()} | {:error, String.t()}
  def build_for_folder(root_path, question) when is_binary(root_path) and is_binary(question) do
    if File.dir?(root_path) do
      files =
        root_path
        |> folder_file_paths_for_prompt()
        |> Enum.take(@max_folder_files)
        |> Enum.map(&read_prompt_file(&1, @folder_file_max_chars))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, file} -> file end)
        |> trim_files_to_total_budget(@max_total_chars)

      {:ok,
       %{
         mode: :folder,
         root_path: root_path,
         question: question,
         primary_path: nil,
         files: files,
         messages: build_messages(files, root_path, question, nil)
       }}
    else
      {:error, "Root path is not a directory: #{root_path}"}
    end
  end

  @spec related_file_paths_for_refactor(String.t(), String.t(), String.t(), String.t()) :: [
          String.t()
        ]
  def related_file_paths_for_refactor(file_path, file_content, question, root_path)
      when is_binary(file_path) and is_binary(file_content) and is_binary(question) and
             is_binary(root_path) do
    analysis = analyze_file(file_content)
    question_modules = module_names_from_question(question)

    target_modules =
      question_modules
      |> Kernel.++(analysis.defined_modules)
      |> Kernel.++(analysis.referenced_modules)
      |> Enum.uniq()

    definition_paths =
      target_modules
      |> Enum.flat_map(&find_module_definition_paths(&1, root_path))

    caller_paths =
      analysis.defined_modules
      |> Enum.flat_map(&find_module_caller_paths(&1, root_path))

    function_caller_paths =
      analysis.defined_modules
      |> Enum.flat_map(fn module_name ->
        Enum.flat_map(analysis.public_functions, fn function_name ->
          find_function_caller_paths(module_name, function_name, root_path)
        end)
      end)

    convention_paths = convention_related_paths(file_path, root_path)

    definition_paths
    |> Kernel.++(caller_paths)
    |> Kernel.++(function_caller_paths)
    |> Kernel.++(convention_paths)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&wanted_file?/1)
  end

  @spec module_names_from_question(String.t()) :: [String.t()]
  def module_names_from_question(question) when is_binary(question) do
    ~r/\b(?:[A-Z][A-Za-z0-9_]*)(?:\.[A-Z][A-Za-z0-9_]*)+\b/
    |> Regex.scan(question)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  @spec find_module_definition_paths(String.t(), String.t()) :: [String.t()]
  def find_module_definition_paths(module_name, root_path)
      when is_binary(module_name) and is_binary(root_path) do
    run_rg_paths(["-l", "defmodule #{module_name}", root_path])
  end

  @spec find_module_caller_paths(String.t(), String.t()) :: [String.t()]
  def find_module_caller_paths(module_name, root_path)
      when is_binary(module_name) and is_binary(root_path) do
    short_name =
      module_name
      |> String.split(".")
      |> List.last()

    run_rg_paths(["-l", module_name, root_path]) ++
      run_rg_paths(["-l", "alias #{short_name}", root_path]) ++
      run_rg_paths(["-l", "use #{short_name}", root_path])
  end

  @spec find_function_caller_paths(String.t(), atom(), String.t()) :: [String.t()]
  def find_function_caller_paths(module_name, function_name, root_path)
      when is_binary(module_name) and is_atom(function_name) and is_binary(root_path) do
    short_name =
      module_name
      |> String.split(".")
      |> List.last()

    function_string = Atom.to_string(function_name)

    run_rg_paths(["-l", "#{module_name}.#{function_string}", root_path]) ++
      run_rg_paths(["-l", "#{short_name}.#{function_string}", root_path])
  end

  @spec folder_file_paths_for_prompt(String.t()) :: [String.t()]
  def folder_file_paths_for_prompt(root_path) when is_binary(root_path) do
    root_path
    |> list_files_recursive()
    |> Enum.filter(&wanted_file?/1)
  end

  @spec list_files_recursive(String.t()) :: [String.t()]
  def list_files_recursive(root_path) when is_binary(root_path) do
    root_path
    |> Path.expand()
    |> do_list_files_recursive()
    |> Enum.sort()
  end

  @spec analyze_file(String.t()) :: analysis()
  def analyze_file(file_content) when is_binary(file_content) do
    case Code.string_to_quoted(file_content) do
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

              {:defdelegate, _, args} = node, acc ->
                delegated_module = extract_defdelegate_target(args)
                delegated_function = extract_function_name(args)

                updated_acc =
                  acc
                  |> maybe_prepend(:referenced_modules, delegated_module)
                  |> maybe_prepend(:public_functions, delegated_function)

                {node, updated_acc}

              {:def, _, [{name, _, _args}, _body]} = node, acc when is_atom(name) ->
                {node, update_in(acc.public_functions, &[name | &1])}

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

  defp do_list_files_recursive(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn name ->
          full_path = Path.join(path, name)

          case File.stat(full_path) do
            {:ok, %{type: :directory}} ->
              if skip_directory?(full_path) do
                []
              else
                do_list_files_recursive(full_path)
              end

            {:ok, %{type: :regular}} ->
              [full_path]

            _ ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp build_messages([], root_path, question, _primary_path) do
    Prompts.editor_folder_question(root_path, question)
  end

  defp build_messages(files, root_path, question, primary_path) do
    relative_files = relativize_paths(files, root_path)

    relative_primary_path =
      if is_binary(primary_path) do
        Path.relative_to(primary_path, root_path)
      else
        nil
      end

    Prompts.editor_files_question(
      relative_files,
      question,
      primary_path: relative_primary_path
    )
  end

  defp relativize_paths(files, root_path) do
    Enum.map(files, fn %{path: path, content: content} ->
      %{path: Path.relative_to(path, root_path), content: content}
    end)
  end

  defp context_mode([_file]), do: :file
  defp context_mode(_files), do: :files

  defp read_prompt_file(path, max_chars) do
    case File.read(path) do
      {:ok, content} ->
        {:ok,
         %{
           path: Path.expand(path),
           content: Prompts.truncate_content(content, max_chars)
         }}

      {:error, reason} ->
        {:error, "Could not read file: #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp trim_files_to_total_budget([], _max_chars), do: []

  defp trim_files_to_total_budget([primary_file | supporting_files], max_chars) do
    primary_size = String.length(primary_file.content)

    cond do
      primary_size >= max_chars ->
        [primary_file]

      true ->
        {kept_supporting, _used_chars} =
          Enum.reduce_while(supporting_files, {[], primary_size}, fn file, {acc, used_chars} ->
            next_size = used_chars + String.length(file.content)

            if next_size > max_chars do
              {:halt, {Enum.reverse(acc), used_chars}}
            else
              {:cont, {[file | acc], next_size}}
            end
          end)

        [primary_file | kept_supporting]
    end
  end

  defp ensure_within_root(path, root_path) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root_path)

    if String.starts_with?(expanded_path, expanded_root) do
      :ok
    else
      {:error, "Path is outside the selected root: #{expanded_path}"}
    end
  end

  defp convention_related_paths(file_path, root_path) do
    basename = Path.basename(file_path, Path.extname(file_path))
    same_dir = Path.dirname(file_path)

    non_test_paths = [
      Path.join(same_dir, "#{basename}.heex"),
      Path.join(same_dir, "#{basename}.html.heex")
    ]

    test_paths = [
      Path.join(same_dir, "#{basename}_test.exs"),
      Path.join(root_path, "test/**/#{basename}_test.exs")
    ]

    non_test_paths
    |> Enum.flat_map(&Path.wildcard/1)
    |> Kernel.++(Enum.flat_map(test_paths, &Path.wildcard/1))
  end

  defp run_rg_paths(args) do
    case System.cmd("rg", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.expand/1)

      {_output, _status} ->
        []
    end
  end

  defp extract_aliases(args) do
    case args do
      [{:__aliases__, _, parts}] ->
        [Enum.join(parts, ".")]

      [[{:__aliases__, _, parts} | _tail]] ->
        [Enum.join(parts, ".")]

      [_meta, aliases] when is_list(aliases) ->
        Enum.flat_map(aliases, fn
          {:__aliases__, _, parts} -> [Enum.join(parts, ".")]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp extract_module_refs(args) do
    Enum.flat_map(args, fn
      {:__aliases__, _, parts} -> [Enum.join(parts, ".")]
      _ -> []
    end)
  end

  defp extract_defdelegate_target(args) do
    args
    |> List.last()
    |> case do
      options when is_list(options) ->
        case Keyword.get(options, :to) do
          {:__aliases__, _, parts} -> Enum.join(parts, ".")
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_function_name(args) do
    case args do
      [{name, _, _} | _] when is_atom(name) -> name
      _ -> nil
    end
  end

  defp maybe_prepend(acc, _key, nil), do: acc

  defp maybe_prepend(acc, key, value) do
    update_in(acc[key], &[value | &1])
  end

  defp wanted_file?(path) do
    Path.extname(path) in @allowed_extensions and not skip_file?(path)
  end

  defp skip_directory?(path) do
    Path.basename(path) in [".git", "_build", "deps", "node_modules"]
  end

  defp skip_file?(path) do
    basename = Path.basename(path)
    String.starts_with?(basename, ".") and basename not in [".formatter.exs"]
  end
end
