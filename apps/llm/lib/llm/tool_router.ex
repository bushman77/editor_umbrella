defmodule Llm.ToolRouter do
  @moduledoc """
  Whitelisted tool definitions and tool execution for local Qwen tool calls.

  Rules:
    * Only tools listed in `tools/0` may be executed.
    * Unknown tools return structured errors.
    * No arbitrary shell execution.
    * File tools must stay inside the provided workspace root.
    * Start read-only. Writes/patches come later behind explicit approval.
  """

  @type tool_name :: String.t()
  @type tool_args :: map()
  @type tool_result :: {:ok, map()} | {:error, map()}

  @default_max_read_bytes 200_000

  @spec tools() :: [map()]
  def tools do
    [
      %{
        type: "function",
        function: %{
          name: "editor_search_workspace",
          description:
            "Searches the whole workspace root for plain text. Use this first when the user asks to search but does not specify a path.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{
                type: "string",
                description: "Absolute workspace root directory."
              },
              query: %{
                type: "string",
                description: "Plain text query to search for."
              },
              case_sensitive: %{
                type: "boolean",
                description: "Whether matching should be case-sensitive. Defaults to false."
              },
              extensions: %{
                type: "array",
                items: %{type: "string"},
                description: "Optional extensions to search, such as .ex, .exs, .heex, .js."
              },
              max_results: %{
                type: "integer",
                description: "Maximum number of matching lines to return. Defaults to 100."
              }
            },
            required: ["root", "query"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "echo_hello_world",
          description: "Runs a whitelisted echo command that returns Hello World.",
          parameters: %{
            type: "object",
            properties: %{},
            required: []
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_read_file",
          description:
            "Reads one text/source file from inside a workspace root. The file path must resolve inside the provided root.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{
                type: "string",
                description: "Absolute workspace root directory."
              },
              path: %{
                type: "string",
                description:
                  "File path to read. Prefer a path relative to root, such as apps/llm/lib/llm/client.ex."
              },
              max_bytes: %{
                type: "integer",
                description:
                  "Maximum bytes to return. Defaults to 200000. Large files are truncated."
              }
            },
            required: ["root", "path"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_list_files",
          description:
            "Lists source/text files inside a workspace directory. The path must resolve inside the provided root.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{
                type: "string",
                description: "Absolute workspace root directory."
              },
              path: %{
                type: "string",
                description: "Directory path to list. Defaults to ."
              },
              recursive: %{
                type: "boolean",
                description: "Whether to recurse into subdirectories. Defaults to true."
              },
              max_entries: %{
                type: "integer",
                description: "Maximum number of files to return. Defaults to 200."
              },
              extensions: %{
                type: "array",
                items: %{type: "string"},
                description: "Optional file extensions to include, such as .ex, .exs, .heex, .js."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_search_text",
          description:
            "Searches source/text files inside a workspace root using plain text matching. Paths are workspace-clamped. No regex and no shell execution.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{
                type: "string",
                description: "Absolute workspace root directory."
              },
              path: %{
                type: "string",
                description: "Directory or file path to search. Defaults to ."
              },
              query: %{
                type: "string",
                description: "Plain text query to search for."
              },
              recursive: %{
                type: "boolean",
                description: "Whether to recurse into subdirectories. Defaults to true."
              },
              case_sensitive: %{
                type: "boolean",
                description: "Whether matching should be case-sensitive. Defaults to false."
              },
              extensions: %{
                type: "array",
                items: %{type: "string"},
                description: "Optional extensions to search, such as .ex, .exs, .heex, .js."
              },
              max_results: %{
                type: "integer",
                description: "Maximum number of matching lines to return. Defaults to 100."
              }
            },
            required: ["root", "query"]
          }
        }
      }
    ]
  end

  def call("editor_search_workspace", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, query} <- required_string(args, "query"),
         {:ok, case_sensitive?} <- optional_boolean(args, "case_sensitive", false),
         {:ok, max_results} <- positive_integer_arg(args, "max_results", 100),
         {:ok, extensions} <- optional_extensions(args),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, stat} <- file_stat(absolute_root),
         {:ok, matches, truncated?} <-
           search_text(
             absolute_root,
             absolute_root,
             stat,
             query,
             true,
             case_sensitive?,
             search_extensions(extensions),
             max_results
           ) do
      {:ok,
       %{
         root: absolute_root,
         path: ".",
         absolute_path: absolute_root,
         query: query,
         recursive: true,
         case_sensitive: case_sensitive?,
         extensions: search_extensions(extensions),
         count: length(matches),
         truncated: truncated?,
         matches: matches
       }}
    end
  end

  def call("editor_list_files", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, path} <- optional_string(args, "path", "."),
         {:ok, recursive?} <- optional_boolean(args, "recursive", true),
         {:ok, max_entries} <- positive_integer_arg(args, "max_entries", 200),
         {:ok, extensions} <- optional_extensions(args),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, absolute_path} <- resolve_inside_root(absolute_root, path),
         {:ok, stat} <- file_stat(absolute_path),
         :ok <- directory?(stat),
         {:ok, files, truncated?} <-
           list_files(absolute_root, absolute_path, recursive?, extensions, max_entries) do
      {:ok,
       %{
         root: absolute_root,
         path: Path.relative_to(absolute_path, absolute_root),
         absolute_path: absolute_path,
         recursive: recursive?,
         max_entries: max_entries,
         extensions: extensions,
         count: length(files),
         truncated: truncated?,
         files: files
       }}
    end
  end

  def call("editor_search_text", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, query} <- required_string(args, "query"),
         {:ok, path} <- optional_string(args, "path", "."),
         {:ok, recursive?} <- optional_boolean(args, "recursive", true),
         {:ok, case_sensitive?} <- optional_boolean(args, "case_sensitive", false),
         {:ok, max_results} <- positive_integer_arg(args, "max_results", 100),
         {:ok, extensions} <- optional_extensions(args),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, absolute_path} <- resolve_inside_root(absolute_root, path),
         {:ok, stat} <- file_stat(absolute_path),
         {:ok, matches, truncated?} <-
           search_text(
             absolute_root,
             absolute_path,
             stat,
             query,
             recursive?,
             case_sensitive?,
             search_extensions(extensions),
             max_results
           ) do
      {:ok,
       %{
         root: absolute_root,
         path: Path.relative_to(absolute_path, absolute_root),
         absolute_path: absolute_path,
         query: query,
         recursive: recursive?,
         case_sensitive: case_sensitive?,
         extensions: search_extensions(extensions),
         count: length(matches),
         truncated: truncated?,
         matches: matches
       }}
    end
  end

  @spec call(tool_name(), tool_args()) :: tool_result()
  def call("echo_hello_world", args) when is_map(args) do
    {:ok,
     %{
       command: "echo Hello World",
       stdout: "Hello World",
       exit_status: 0
     }}
  end

  def call("editor_read_file", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, path} <- required_string(args, "path"),
         {:ok, max_bytes} <- max_bytes(args),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, absolute_path} <- resolve_inside_root(absolute_root, path),
         {:ok, stat} <- file_stat(absolute_path),
         :ok <- regular_file?(stat),
         {:ok, content, truncated?} <- read_limited(absolute_path, max_bytes) do
      {:ok,
       %{
         path: Path.relative_to(absolute_path, absolute_root),
         absolute_path: absolute_path,
         root: absolute_root,
         byte_size: stat.size,
         returned_bytes: byte_size(content),
         truncated: truncated?,
         content: content
       }}
    end
  end

  def call(name, args) when is_binary(name) and is_map(args) do
    {:error,
     %{
       error: "unknown_tool",
       tool: name
     }}
  end

  defp required_string(args, key) do
    value = Map.get(args, key) || Map.get(args, String.to_atom(key))

    case value do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error, %{error: "blank_argument", argument: key}}
        else
          {:ok, value}
        end

      _other ->
        {:error, %{error: "missing_argument", argument: key}}
    end
  end

  defp max_bytes(args) do
    value = Map.get(args, "max_bytes") || Map.get(args, :max_bytes) || @default_max_read_bytes

    cond do
      is_integer(value) and value > 0 ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _other -> {:error, %{error: "invalid_argument", argument: "max_bytes"}}
        end

      true ->
        {:error, %{error: "invalid_argument", argument: "max_bytes"}}
    end
  end

  defp workspace_root(root) do
    absolute_root = root |> Path.expand() |> Path.absname()

    case File.dir?(absolute_root) do
      true -> {:ok, absolute_root}
      false -> {:error, %{error: "workspace_root_not_found", root: absolute_root}}
    end
  end

  defp resolve_inside_root(absolute_root, path) do
    absolute_path =
      path
      |> Path.expand(absolute_root)
      |> Path.absname()

    if inside_root?(absolute_root, absolute_path) do
      {:ok, absolute_path}
    else
      {:error,
       %{
         error: "path_outside_workspace",
         root: absolute_root,
         path: path,
         resolved_path: absolute_path
       }}
    end
  end

  defp inside_root?(absolute_root, absolute_path) do
    absolute_path == absolute_root or String.starts_with?(absolute_path, absolute_root <> "/")
  end

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, stat} ->
        {:ok, stat}

      {:error, reason} ->
        {:error,
         %{
           error: "file_stat_failed",
           path: path,
           reason: inspect(reason)
         }}
    end
  end

  defp regular_file?(%File.Stat{type: :regular}), do: :ok

  defp regular_file?(%File.Stat{type: type}) do
    {:error,
     %{
       error: "not_a_regular_file",
       type: inspect(type)
     }}
  end

  defp read_limited(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          data = IO.binread(io, max_bytes + 1)

          case data do
            data when is_binary(data) and byte_size(data) > max_bytes ->
              <<content::binary-size(max_bytes), _rest::binary>> = data
              {:ok, content, true}

            data when is_binary(data) ->
              {:ok, data, false}

            :eof ->
              {:ok, "", false}

            {:error, reason} ->
              {:error,
               %{
                 error: "file_read_failed",
                 path: path,
                 reason: inspect(reason)
               }}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error,
         %{
           error: "file_open_failed",
           path: path,
           reason: inspect(reason)
         }}
    end
  end

  defp optional_string(args, key, default) do
    value = Map.get(args, key) || Map.get(args, String.to_atom(key)) || default

    case value do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:ok, default}
        else
          {:ok, value}
        end

      _other ->
        {:error, %{error: "invalid_argument", argument: key}}
    end
  end

  defp optional_boolean(args, key, default) do
    value = Map.get(args, key) || Map.get(args, String.to_atom(key))

    case value do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, %{error: "invalid_argument", argument: key}}
    end
  end

  defp positive_integer_arg(args, key, default) do
    value = Map.get(args, key) || Map.get(args, String.to_atom(key)) || default

    cond do
      is_integer(value) and value > 0 ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _other -> {:error, %{error: "invalid_argument", argument: key}}
        end

      true ->
        {:error, %{error: "invalid_argument", argument: key}}
    end
  end

  defp optional_extensions(args) do
    value = Map.get(args, "extensions") || Map.get(args, :extensions) || []

    case value do
      extensions when is_list(extensions) ->
        extensions =
          extensions
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn ext ->
            if String.starts_with?(ext, ".") do
              ext
            else
              "." <> ext
            end
          end)
          |> Enum.uniq()

        {:ok, extensions}

      _other ->
        {:error, %{error: "invalid_argument", argument: "extensions"}}
    end
  end

  defp directory?(%File.Stat{type: :directory}), do: :ok

  defp directory?(%File.Stat{type: type}) do
    {:error,
     %{
       error: "not_a_directory",
       type: inspect(type)
     }}
  end

  defp list_files(root, start_dir, recursive?, extensions, max_entries) do
    case collect_files(root, start_dir, recursive?, extensions, max_entries, []) do
      {:ok, files, truncated?} ->
        {:ok, Enum.reverse(files), truncated?}

      {:error, error} ->
        {:error, error}
    end
  end

  defp collect_files(_root, _dir, _recursive?, _extensions, max_entries, acc)
       when length(acc) >= max_entries do
    {:ok, acc, true}
  end

  defp collect_files(root, dir, recursive?, extensions, max_entries, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, acc, false}, fn name, {:ok, current_acc, _truncated?} ->
          cond do
            length(current_acc) >= max_entries ->
              {:halt, {:ok, current_acc, true}}

            excluded_directory?(name) ->
              {:cont, {:ok, current_acc, false}}

            true ->
              path = Path.join(dir, name)

              case File.stat(path) do
                {:ok, %File.Stat{type: :regular, size: size}} ->
                  if file_extension_allowed?(path, extensions) do
                    file = %{
                      path: Path.relative_to(path, root),
                      byte_size: size
                    }

                    {:cont, {:ok, [file | current_acc], false}}
                  else
                    {:cont, {:ok, current_acc, false}}
                  end

                {:ok, %File.Stat{type: :directory}} ->
                  cond do
                    not recursive? ->
                      {:cont, {:ok, current_acc, false}}

                    true ->
                      case collect_files(
                             root,
                             path,
                             recursive?,
                             extensions,
                             max_entries,
                             current_acc
                           ) do
                        {:ok, next_acc, true} -> {:halt, {:ok, next_acc, true}}
                        {:ok, next_acc, false} -> {:cont, {:ok, next_acc, false}}
                        {:error, _error} -> {:cont, {:ok, current_acc, false}}
                      end
                  end

                {:ok, _stat} ->
                  {:cont, {:ok, current_acc, false}}

                {:error, _reason} ->
                  {:cont, {:ok, current_acc, false}}
              end
          end
        end)

      {:error, _reason} ->
        {:ok, acc, false}
    end
  end

  defp excluded_directory?(name) do
    name in [
      ".git",
      ".elixir_ls",
      ".cache",
      ".codex",
      "_build",
      "deps",
      "node_modules",
      "cover",
      "tmp",
      "log",
      "logs",
      "dist",
      "build"
    ] or String.starts_with?(name, "Mnesia.")
  end

  defp file_extension_allowed?(_path, []), do: true

  defp file_extension_allowed?(path, extensions) do
    Path.extname(path) in extensions
  end

  defp search_extensions([]) do
    [
      ".ex",
      ".exs",
      ".heex",
      ".eex",
      ".js",
      ".ts",
      ".css",
      ".html",
      ".md",
      ".txt",
      ".json",
      ".jsonc",
      ".lock",
      ".toml",
      ".yml",
      ".yaml"
    ]
  end

  defp search_extensions(extensions), do: extensions

  defp search_text(
         root,
         path,
         %File.Stat{type: :regular},
         query,
         _recursive?,
         case_sensitive?,
         extensions,
         max_results
       ) do
    if file_extension_allowed?(path, extensions) do
      search_files(root, [path], query, case_sensitive?, max_results)
    else
      {:ok, [], false}
    end
  end

  defp search_text(
         root,
         path,
         %File.Stat{type: :directory},
         query,
         recursive?,
         case_sensitive?,
         extensions,
         max_results
       ) do
    with {:ok, files, _files_truncated?} <-
           list_files(root, path, recursive?, extensions, 2_000) do
      file_paths =
        Enum.map(files, fn %{path: relative_path} ->
          Path.join(root, relative_path)
        end)

      search_files(root, file_paths, query, case_sensitive?, max_results)
    end
  end

  defp search_text(
         _root,
         _path,
         %File.Stat{type: type},
         _query,
         _recursive?,
         _case_sensitive?,
         _extensions,
         _max_results
       ) do
    {:error,
     %{
       error: "not_searchable",
       type: inspect(type)
     }}
  end

  defp search_files(root, file_paths, query, case_sensitive?, max_results) do
    normalized_query = normalize_search_text(query, case_sensitive?)

    {matches, truncated?} =
      Enum.reduce_while(file_paths, {[], false}, fn file_path, {matches, _truncated?} ->
        remaining = max_results - length(matches)

        cond do
          remaining <= 0 ->
            {:halt, {matches, true}}

          true ->
            case search_file(root, file_path, normalized_query, case_sensitive?, remaining) do
              {:ok, file_matches, file_truncated?} ->
                next_matches = matches ++ file_matches

                if file_truncated? or length(next_matches) >= max_results do
                  {:halt, {next_matches, true}}
                else
                  {:cont, {next_matches, false}}
                end

              {:skip, _reason} ->
                {:cont, {matches, false}}

              {:error, _error} ->
                {:cont, {matches, false}}
            end
        end
      end)

    {:ok, matches, truncated?}
  end

  defp search_file(root, file_path, normalized_query, case_sensitive?, remaining) do
    with {:ok, stat} <- File.stat(file_path),
         true <- stat.type == :regular,
         true <- stat.size <= 500_000,
         {:ok, content} <- File.read(file_path),
         true <- String.valid?(content) do
      lines =
        content
        |> String.split("\n")
        |> Enum.with_index(1)

      {matches, truncated?} =
        Enum.reduce_while(lines, {[], false}, fn {line, line_number}, {matches, _truncated?} ->
          normalized_line = normalize_search_text(line, case_sensitive?)

          if String.contains?(normalized_line, normalized_query) do
            match = %{
              path: Path.relative_to(file_path, root),
              line: line_number,
              preview: preview_line(line)
            }

            next_matches = matches ++ [match]

            if length(next_matches) >= remaining do
              {:halt, {next_matches, true}}
            else
              {:cont, {next_matches, false}}
            end
          else
            {:cont, {matches, false}}
          end
        end)

      {:ok, matches, truncated?}
    else
      false -> {:skip, :not_text_or_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_search_text(text, true), do: text
  defp normalize_search_text(text, false), do: String.downcase(text)

  defp preview_line(line) do
    line
    |> String.trim()
    |> String.slice(0, 240)
  end
end
