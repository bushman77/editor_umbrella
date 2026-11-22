defmodule EditorWeb.RelatedContext do
  @moduledoc """
  Formats the related-files tab bar into the `RELATED CONTEXT` prompt section.

  For each related file the model gets the contracts of the functions the
  current file calls there: the `@spec` when one exists, otherwise the function
  head. Bodies are left out; the model reads a file when it needs one.

  Pure: callers pass the selected file and the related-file specs built by
  `EditorWeb.EditorLlm.related_file_specs/1` (which already honours the
  include/exclude toggles in the tab bar).
  """

  @groups [
    {"uses", "Dependencies (current file uses these)"},
    {"used by", "Consumers (these use the current file)"},
    {"uses/used by", "Bidirectional (tightly coupled)"},
    {"test/template", "Tests & Templates"},
    {"related", "Other files you included"}
  ]

  @max_files_per_group 8
  @max_contracts_per_file 8

  @type function_info :: %{
          optional(:name) => String.t(),
          optional(:spec) => String.t() | nil,
          optional(:head) => String.t()
        }

  @type related_spec :: %{
          required(:path) => String.t(),
          optional(:relationship) => String.t(),
          optional(:functions) => [function_info()]
        }

  @doc "The prompt section, or `\"\"` when there is nothing to send."
  @spec format(String.t() | nil, [related_spec()]) :: String.t()
  def format(nil, _related_specs), do: ""
  def format(_selected_file, []), do: ""

  def format(selected_file, related_specs)
      when is_binary(selected_file) and is_list(related_specs) do
    by_relationship = Enum.group_by(related_specs, &Map.get(&1, :relationship, "related"))

    sections =
      @groups
      |> Enum.map(fn {relationship, label} ->
        format_group(Map.get(by_relationship, relationship, []), label)
      end)
      |> Enum.reject(&(&1 == ""))

    if sections == [] do
      ""
    else
      """
      === RELATED CONTEXT (pre-discovered by editor) ===
      Current file: #{selected_file}

      #{Enum.join(sections, "\n\n")}

      Signatures are the public contracts the current file calls in each file, found
      through AST analysis. Use them directly; read a file with editor_read_file only
      when you need a function body. Prioritize Dependencies and Consumers when
      judging the impact of a change.
      """
    end
  end

  @doc """
  One line per called function: its `@spec` if it has one, otherwise its head
  without the trailing `do`. Multi-clause functions appear once.
  """
  @spec contract_lines([function_info()]) :: [String.t()]
  def contract_lines(functions) when is_list(functions) do
    functions
    |> Enum.group_by(&Map.get(&1, :name), & &1)
    |> Enum.sort_by(fn {_name, clauses} -> first_index(functions, hd(clauses)) end)
    |> Enum.map(fn {_name, clauses} -> contract_line(clauses) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@max_contracts_per_file)
  end

  defp format_group([], _label), do: ""

  defp format_group(specs, label) do
    entries =
      specs
      |> Enum.take(@max_files_per_group)
      |> Enum.map_join("\n", &format_file/1)

    "#{label}:\n#{entries}"
  end

  defp format_file(%{path: path} = spec) do
    case spec |> Map.get(:functions, []) |> contract_lines() do
      [] -> "  - #{path}"
      lines -> "  - #{path}\n" <> Enum.map_join(lines, "\n", &("      " <> &1))
    end
  end

  defp contract_line(clauses) do
    case Enum.find_value(clauses, &present(Map.get(&1, :spec))) do
      nil -> clauses |> Enum.find_value(&present(Map.get(&1, :head))) |> strip_do()
      spec -> spec
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil

  defp strip_do(nil), do: nil

  defp strip_do(head) do
    head
    |> String.replace(~r/,\s*do:.*\z/s, "")
    |> String.replace(~r/\s+do\s*\z/, "")
  end

  defp first_index(functions, function) do
    Enum.find_index(functions, &(&1 == function)) || 0
  end
end
