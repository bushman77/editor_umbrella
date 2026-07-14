defmodule Llm.ToolRouter do
  @moduledoc """
  Whitelisted tool definitions and tool execution for local Qwen tool calls.

  Rules:
    * Only tools listed in `tools/0` may be executed.
    * Unknown tools return structured errors.
    * No arbitrary shell execution.
    * File tools must stay inside the provided workspace root.
  """

  @type tool_name :: String.t()
  @type tool_args :: map()
  @type tool_result :: {:ok, map()} | {:error, map()}

  @default_max_read_bytes 200_000

  @spec tools() :: [map()]
  def tools do
    [
      # Add to tools/0 list
      %{
        type: "function",
        function: %{
          name: "editor_patch_file",
          description:
            "Applies a search-and-replace patch to a file. More efficient than rewriting the whole file. The search text must match exactly (including whitespace). Returns the patched content for verification.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{type: "string", description: "File path to patch."},
              search: %{type: "string", description: "The exact text to find in the file."},
              replace: %{type: "string", description: "The text to replace the search text with."},
              all: %{
                type: "boolean",
                description:
                  "If true, replace all occurrences. If false (default), only replace the first."
              }
            },
            required: ["root", "path", "search", "replace"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_git_diff_stat",
          description:
            "Shows a compact summary of which files changed and how many insertions/deletions. Faster than full diff for understanding scope of changes.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{type: "string", description: "Optional file or directory path to limit."},
              ref: %{
                type: "string",
                description:
                  "Optional commit/branch to compare against HEAD. Defaults to HEAD (uncommitted changes)."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "mix_deps_get",
          description:
            "Runs mix deps.get to fetch and install project dependencies. Use this when dependencies are missing or need updating before compiling or running tests.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              timeout_ms: %{
                type: "integer",
                description:
                  "Maximum execution time in milliseconds. Defaults to 120000 (2 minutes)."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "mix_test",
          description:
            "Runs the Elixir test suite using mix test. Can run all tests, a specific test file, or a specific test at a line number. Returns test output including failures and errors. Use this to verify code changes work correctly.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{
                type: "string",
                description: "Optional test file path to run, e.g. test/my_app_test.exs"
              },
              line: %{
                type: "integer",
                description:
                  "Optional line number to run a specific test. Must be used with path."
              },
              timeout_ms: %{
                type: "integer",
                description:
                  "Maximum execution time in milliseconds. Defaults to 120000 (2 minutes)."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "mix_compile",
          description:
            "Compiles the Elixir project using mix compile. Returns compiler output including warnings and errors. Use this to check if code changes compile before running tests.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              warnings_as_errors: %{
                type: "boolean",
                description: "Treat warnings as errors. Defaults to false."
              },
              timeout_ms: %{
                type: "integer",
                description:
                  "Maximum execution time in milliseconds. Defaults to 60000 (1 minute)."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_git_diff",
          description:
            "Shows git diffs. Can show uncommitted changes (unstaged, staged, or all vs HEAD), a specific commit, or diff between two refs. Optional path limits to a specific file or directory.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{
                type: "string",
                description: "Optional file or directory path to limit the diff."
              },
              mode: %{
                type: "string",
                enum: ["unstaged", "staged", "all", "commit", "between"],
                description:
                  "Diff mode: 'unstaged' (working tree vs index), 'staged' (index vs HEAD), 'all' (working tree vs HEAD, default), 'commit' (show specific commit, requires 'ref'), 'between' (diff two refs, requires 'ref' and 'ref2')."
              },
              ref: %{
                type: "string",
                description:
                  "Commit hash, branch, or tag. Required for 'commit' mode, first ref for 'between' mode."
              },
              ref2: %{
                type: "string",
                description: "Second ref for 'between' mode (commit hash, branch, or tag)."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_git_log",
          description:
            "Shows recent commit history. Optional path limits to commits touching a specific file.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{type: "string", description: "Optional file path to limit log entries."},
              limit: %{
                type: "integer",
                description: "Maximum number of commits to return. Defaults to 10."
              }
            },
            required: ["root"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "editor_git_blame",
          description:
            "Shows who wrote specific lines and when. Useful for understanding why code looks the way it does.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{type: "string", description: "File path to blame."},
              start_line: %{type: "integer", description: "First line number to blame."},
              end_line: %{type: "integer", description: "Last line number to blame."}
            },
            required: ["root", "path", "start_line", "end_line"]
          }
        }
      },
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
      },
      %{
        type: "function",
        function: %{
          name: "editor_write_file",
          description: "Writes or overwrites a file inside the workspace root.",
          parameters: %{
            type: "object",
            properties: %{
              root: %{type: "string", description: "Absolute workspace root directory."},
              path: %{type: "string", description: "File path to write."},
              content: %{
                type: "string",
                description: "The full text content to write to the file."
              }
            },
            required: ["root", "path", "content"]
          }
        }
      }
    ]
  end

  def call("mix_test", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, path} <- optional_string(args, "path", nil),
         {:ok, line} <- optional_integer(args, "line", nil),
         {:ok, timeout_ms} <- positive_integer_arg(args, "timeout_ms", 120_000),
         {:ok, test_args} <- build_test_args(absolute_root, path, line),
         {:ok, output, exit_status, timed_out?} <-
           run_mix_task(absolute_root, "test", test_args, timeout_ms) do
      {:ok,
       %{
         root: absolute_root,
         path: path,
         line: line,
         exit_status: exit_status,
         timed_out: timed_out?,
         output: truncate_task_output(output)
       }}
    end
  end

  def call("mix_deps_get", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, timeout_ms} <- positive_integer_arg(args, "timeout_ms", 120_000),
         {:ok, output, exit_status, timed_out?} <-
           run_mix_task(absolute_root, "deps.get", [], timeout_ms) do
      {:ok,
       %{
         root: absolute_root,
         exit_status: exit_status,
         timed_out: timed_out?,
         output: truncate_task_output(output)
       }}
    end
  end

  def call("mix_compile", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, warnings_as_errors?} <- optional_boolean(args, "warnings_as_errors", false),
         {:ok, timeout_ms} <- positive_integer_arg(args, "timeout_ms", 60_000),
         compile_args <- build_compile_args(warnings_as_errors?),
         {:ok, output, exit_status, timed_out?} <-
           run_mix_task(absolute_root, "compile", compile_args, timeout_ms) do
      {:ok,
       %{
         root: absolute_root,
         warnings_as_errors: warnings_as_errors?,
         exit_status: exit_status,
         timed_out: timed_out?,
         output: truncate_task_output(output)
       }}
    end
  end

  def call("editor_git_diff", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, absolute_root} <- workspace_root(root),
         :ok <- ensure_git_repo(absolute_root),
         {:ok, path_arg} <- optional_string(args, "path", nil),
         {:ok, mode} <- optional_string(args, "mode", "all"),
         :ok <- validate_diff_mode(mode),
         {:ok, ref} <- optional_string(args, "ref", nil),
         {:ok, ref2} <- optional_string(args, "ref2", nil),
         :ok <- validate_diff_refs(mode, ref, ref2),
         {:ok, absolute_path} <- maybe_resolve_path(absolute_root, path_arg),
         {:ok, git_args} <- build_diff_args(mode, ref, ref2, absolute_path),
         {:ok, output, exit_status} <- run_git(absolute_root, git_args) do
      {:ok,
       %{
         root: absolute_root,
         path: path_arg,
         mode: mode,
         ref: ref,
         ref2: ref2,
         exit_status: exit_status,
         diff: truncate_git_output(output)
       }}
    end
  end

  def call("editor_git_diff_stat", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, absolute_root} <- workspace_root(root),
         :ok <- ensure_git_repo(absolute_root),
         {:ok, path_arg} <- optional_string(args, "path", nil),
         {:ok, ref} <- optional_string(args, "ref", "HEAD"),
         {:ok, absolute_path} <- maybe_resolve_path(absolute_root, path_arg),
         {:ok, output, exit_status} <-
           run_git(absolute_root, ["diff", "--stat", ref] ++ path_args(absolute_path)) do
      {:ok,
       %{
         root: absolute_root,
         path: path_arg,
         ref: ref,
         exit_status: exit_status,
         stat: truncate_git_output(output)
       }}
    end
  end

  defp validate_diff_mode(mode) when mode in ["unstaged", "staged", "all", "commit", "between"],
    do: :ok

  defp validate_diff_mode(_mode),
    do:
      {:error,
       %{
         error: "invalid_diff_mode",
         valid_modes: ["unstaged", "staged", "all", "commit", "between"]
       }}

  defp validate_diff_refs("commit", nil, _ref2),
    do: {:error, %{error: "missing_ref", message: "commit mode requires 'ref' parameter"}}

  defp validate_diff_refs("between", nil, _ref2),
    do: {:error, %{error: "missing_ref", message: "between mode requires 'ref' parameter"}}

  defp validate_diff_refs("between", _ref, nil),
    do: {:error, %{error: "missing_ref2", message: "between mode requires 'ref2' parameter"}}

  defp validate_diff_refs(_mode, _ref, _ref2), do: :ok

  defp build_diff_args("unstaged", nil, nil, absolute_path) do
    {:ok, ["diff"] ++ path_args(absolute_path)}
  end

  defp build_diff_args("staged", nil, nil, absolute_path) do
    {:ok, ["diff", "--cached"] ++ path_args(absolute_path)}
  end

  defp build_diff_args("all", nil, nil, absolute_path) do
    {:ok, ["diff", "HEAD"] ++ path_args(absolute_path)}
  end

  defp build_diff_args("commit", ref, nil, absolute_path) do
    {:ok, ["show", ref] ++ path_args(absolute_path)}
  end

  defp build_diff_args("between", ref, ref2, absolute_path) do
    {:ok, ["diff", ref, ref2] ++ path_args(absolute_path)}
  end

  defp build_diff_args(_mode, _ref, _ref2, _absolute_path) do
    {:error, %{error: "invalid_diff_args"}}
  end

  def call("editor_git_log", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, absolute_root} <- workspace_root(root),
         :ok <- ensure_git_repo(absolute_root),
         {:ok, path_arg} <- optional_string(args, "path", nil),
         {:ok, limit} <- positive_integer_arg(args, "limit", 10),
         {:ok, absolute_path} <- maybe_resolve_path(absolute_root, path_arg),
         {:ok, output, exit_status} <-
           run_git(absolute_root, ["log", "--oneline", "-#{limit}"] ++ path_args(absolute_path)) do
      {:ok,
       %{
         root: absolute_root,
         path: path_arg,
         limit: limit,
         exit_status: exit_status,
         commits: parse_git_log(output)
       }}
    end
  end

  def call("editor_git_blame", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, path} <- required_string(args, "path"),
         {:ok, start_line} <- positive_integer_arg(args, "start_line", 1),
         {:ok, end_line} <- positive_integer_arg(args, "end_line", start_line),
         :ok <- validate_line_range(start_line, end_line),
         {:ok, absolute_root} <- workspace_root(root),
         :ok <- ensure_git_repo(absolute_root),
         {:ok, absolute_path} <- resolve_inside_root(absolute_root, path),
         {:ok, output, exit_status} <-
           run_git(absolute_root, [
             "blame",
             "-L",
             "#{start_line},#{end_line}",
             "--",
             absolute_path
           ]) do
      {:ok,
       %{
         root: absolute_root,
         path: Path.relative_to(absolute_path, absolute_root),
         start_line: start_line,
         end_line: end_line,
         exit_status: exit_status,
         blame: truncate_git_output(output)
       }}
    end
  end

  @spec call(tool_name(), tool_args()) :: tool_result()
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
         # Safety net: force real workspace root if placeholder detected
         absolute_root <-
           if(String.contains?(root, "path/to/your") or root == ".", do: File.cwd!(), else: root),
         {:ok, absolute_root} <- workspace_root(absolute_root),
         {:ok, path} <- optional_string(args, "path", "."),
         {:ok, recursive?} <- optional_boolean(args, "recursive", true),
         {:ok, max_entries} <- positive_integer_arg(args, "max_entries", 200),
         {:ok, extensions} <- optional_extensions(args),
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
         :ok <- reject_regex_query(query),
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

  def call("editor_write_file", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, path} <- required_string(args, "path"),
         {:ok, content} <- required_string(args, "content"),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, absolute_path} <- resolve_inside_root(absolute_root, path) do
      # Ensure the directory exists
      File.mkdir_p!(Path.dirname(absolute_path))

      case File.write(absolute_path, content) do
        :ok ->
          {:ok,
           %{
             path: Path.relative_to(absolute_path, absolute_root),
             bytes_written: byte_size(content)
           }}

        {:error, reason} ->
          {:error, %{error: "file_write_failed", reason: inspect(reason)}}
      end
    end
  end

  def call(name, args) when is_binary(name) and is_map(args) do
    {:error,
     %{
       error: "unknown_tool",
       tool: name
     }}
  end

  # --- Private Helpers ---

  defp reject_regex_query(query) when is_binary(query) do
    if regex_like_query?(query) do
      {:error,
       %{
         error: "regex_not_supported",
         message:
           "editor_search_text uses plain text matching only. For comments, line patterns, or regex-style inspection, use editor_read_file and inspect the returned file contents."
       }}
    else
      :ok
    end
  end

  defp regex_like_query?(query) do
    String.contains?(query, ["^", "$", ".*", "\\d", "\\s", "\\w", "[", "]", "|"])
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
      nil ->
        {:ok, default}

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

  defp ensure_git_repo(root) do
    git_dir = Path.join(root, ".git")

    if File.dir?(git_dir) or File.regular?(git_dir) do
      :ok
    else
      {:error, %{error: "not_a_git_repo", root: root}}
    end
  end

  defp run_git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output, 0}
      {output, status} -> {:ok, output, status}
    end
  rescue
    error -> {:error, %{error: "git_command_failed", reason: inspect(error)}}
  end

  defp maybe_resolve_path(_root, nil), do: {:ok, nil}
  defp maybe_resolve_path(root, path), do: resolve_inside_root(root, path)

  defp path_args(nil), do: []
  defp path_args(path), do: ["--", path]

  defp truncate_git_output(output) do
    max_chars = 20_000

    if String.length(output) > max_chars do
      String.slice(output, 0, max_chars) <>
        "\n\n[Git output truncated. #{String.length(output) - max_chars} characters omitted.]"
    else
      output
    end
  end

  defp parse_git_log(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, " ", parts: 2) do
        [hash, message] -> %{hash: hash, message: message}
        [hash] -> %{hash: hash, message: ""}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp validate_line_range(start_line, end_line)
       when is_integer(start_line) and is_integer(end_line) and start_line > 0 and
              end_line >= start_line do
    :ok
  end

  defp validate_line_range(_start_line, _end_line) do
    {:error, %{error: "invalid_line_range", message: "start_line must be > 0 and <= end_line"}}
  end

  defp optional_integer(args, key, default) do
    value = Map.get(args, key) || Map.get(args, String.to_atom(key))

    case value do
      nil ->
        {:ok, default}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:ok, default}
        end

      _ ->
        {:ok, default}
    end
  end

  defp build_test_args(_root, nil, nil) do
    {:ok, []}
  end

  defp build_test_args(root, path, nil) do
    with {:ok, absolute_path} <- resolve_inside_root(root, path),
         true <-
           String.ends_with?(absolute_path, "_test.exs") or
             String.ends_with?(absolute_path, "_test.eex") or
             {:error, %{error: "not_a_test_file", path: path}} do
      {:ok, [absolute_path]}
    end
  end

  defp build_test_args(root, path, line) when is_integer(line) and line > 0 do
    with {:ok, absolute_path} <- resolve_inside_root(root, path) do
      {:ok, ["#{absolute_path}:#{line}"]}
    end
  end

  defp build_test_args(_root, _path, _line) do
    {:error, %{error: "invalid_test_args", message: "line must be a positive integer"}}
  end

  defp build_compile_args(true), do: ["--warnings-as-errors"]
  defp build_compile_args(false), do: []

  defp run_mix_task(root, task_name, extra_args, timeout_ms) do
    task =
      Task.async(fn ->
        System.cmd("mix", [task_name | extra_args], cd: root, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, exit_status}} ->
        {:ok, output, exit_status, false}

      nil ->
        {:ok, "mix #{task_name} timed out after #{timeout_ms}ms. The process was killed.", -1,
         true}

      {:exit, reason} ->
        {:error, %{error: "task_crashed", task: task_name, reason: inspect(reason)}}
    end
  rescue
    error ->
      {:error, %{error: "mix_command_failed", task: task_name, reason: Exception.message(error)}}
  end

  defp truncate_task_output(output) do
    max_chars = 30_000

    if String.length(output) > max_chars do
      String.slice(output, 0, max_chars) <>
        "\n\n[Output truncated. #{String.length(output) - max_chars} characters omitted.]"
    else
      output
    end
  end

  def call("editor_patch_file", args) when is_map(args) do
    with {:ok, root} <- required_string(args, "root"),
         {:ok, path} <- required_string(args, "path"),
         {:ok, search} <- required_string(args, "search"),
         {:ok, replace} <- required_string(args, "replace"),
         {:ok, all?} <- optional_boolean(args, "all", false),
         {:ok, absolute_root} <- workspace_root(root),
         {:ok, absolute_path} <- resolve_inside_root(absolute_root, path),
         {:ok, stat} <- file_stat(absolute_path),
         :ok <- regular_file?(stat),
         {:ok, original} <- File.read(absolute_path) do
      cond do
        String.contains?(original, search) ->
          patched = apply_patch(original, search, replace, all?)

          case File.write(absolute_path, patched) do
            :ok ->
              {:ok,
               %{
                 path: Path.relative_to(absolute_path, absolute_root),
                 bytes_written: byte_size(patched),
                 occurrences_replaced: count_replacements(original, search, all?),
                 patched_content: truncate_patch_preview(patched)
               }}

            {:error, reason} ->
              {:error, %{error: "file_write_failed", reason: inspect(reason)}}
          end

        true ->
          # Try whitespace-normalized search as fallback
          case find_normalized_match(original, search) do
            {:ok, normalized_search} ->
              patched = apply_patch(original, normalized_search, replace, all?)

              case File.write(absolute_path, patched) do
                :ok ->
                  {:ok,
                   %{
                     path: Path.relative_to(absolute_path, absolute_root),
                     bytes_written: byte_size(patched),
                     occurrences_replaced: count_replacements(original, normalized_search, all?),
                     note: "Search text was matched using whitespace normalization.",
                     patched_content: truncate_patch_preview(patched)
                   }}

                {:error, reason} ->
                  {:error, %{error: "file_write_failed", reason: inspect(reason)}}
              end

            :error ->
              {:error,
               %{
                 error: "search_text_not_found",
                 message:
                   "The search text was not found in the file. Make sure it matches exactly, including whitespace and indentation.",
                 search_preview: String.slice(search, 0, 200)
               }}
          end
      end
    end
  end

  # Private helpers for patching

  defp apply_patch(original, search, replace, true) do
    String.replace(original, search, replace)
  end

  defp apply_patch(original, search, replace, false) do
    # Replace only first occurrence
    case :binary.match(original, search) do
      {pos, len} ->
        <<before::binary-size(pos), _::binary-size(len), rest::binary>> = original
        before <> replace <> rest

      :nomatch ->
        original
    end
  end

  defp count_replacements(original, search, true) do
    original
    |> String.split(search)
    |> length()
    |> Kernel.-(1)
    |> max(0)
  end

  defp count_replacements(original, search, false) do
    case :binary.match(original, search) do
      {_pos, _len} -> 1
      :nomatch -> 0
    end
  end

  defp truncate_patch_preview(content) do
    max_chars = 5_000

    if String.length(content) > max_chars do
      String.slice(content, 0, max_chars) <>
        "\n\n[Preview truncated. Full file written successfully.]"
    else
      content
    end
  end

  defp find_normalized_match(original, search) do
    # Normalize whitespace in both for comparison
    normalize = fn s ->
      s
      |> String.replace(~r/\r\n/, "\n")
      |> String.trim()
    end

    normalized_search = normalize.(search)

    # Try to find a substring of original that matches when normalized
    original
    |> String.split("\n")
    |> Enum.chunk_every(String.split(search, "\n") |> length(), 1, :discard)
    |> Enum.find_value(fn chunk ->
      candidate = Enum.join(chunk, "\n")

      if normalize.(candidate) == normalized_search do
        {:ok, candidate}
      else
        nil
      end
    end)
    |> case do
      {:ok, _} = match -> match
      nil -> :error
    end
  end
end
