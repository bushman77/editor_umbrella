# apps/llm/lib/llm/architectural_lens.ex
defmodule Llm.ArchitecturalLens do
  @moduledoc """
  Detects architectural layers in an Elixir/OTP project based on
  "Do Fun Things With Big Loud Worker Bees".

  Scans .ex files and categorizes modules by their primary architectural role.
  """

  @spec detect(String.t()) :: %{
          data: [String.t()],
          functional_core: [String.t()],
          boundaries: [String.t()],
          lifecycles: [String.t()],
          workers: [String.t()]
        }
  def detect(root_path) do
    files = find_elixir_files(root_path)
    analyses = files |> Enum.flat_map(&analyze_file/1)

    %{
      data: categorize_data(analyses),
      functional_core: categorize_functional_core(analyses),
      boundaries: categorize_boundaries(analyses),
      lifecycles: categorize_lifecycles(analyses),
      workers: categorize_workers(analyses)
    }
  end

  @spec format_for_prompt(String.t()) :: String.t()
  def format_for_prompt(root_path) do
    layers = detect(root_path)

    """
    This project follows "Do Fun Things With Big Loud Worker Bees":
    - Data: structs and types (#{format_modules(layers.data)})
    - Functional Core: pure business logic (#{format_modules(layers.functional_core)})
    - Tests: verify the core while it's still simple
    - Boundaries: wrap side effects behind APIs (#{format_modules(layers.boundaries)})
    - Lifecycles: supervisors manage startup/shutdown (#{format_modules(layers.lifecycles)})
    - Worker Bees: GenServers for stateful coordination (#{format_modules(layers.workers)})

    When analyzing a module, identify which layer it belongs to.
    """
  end

  # --- File discovery ---

  defp find_elixir_files(root_path) do
    # Try umbrella structure first, then flat lib/
    umbrella = Path.join([root_path, "apps", "*", "lib", "**", "*.ex"]) |> Path.wildcard()
    flat = Path.join([root_path, "lib", "**", "*.ex"]) |> Path.wildcard()

    (umbrella ++ flat)
    |> Enum.reject(&String.contains?(&1, "/_build/"))
    |> Enum.reject(&String.contains?(&1, "/deps/"))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  # --- File analysis ---

  defp analyze_file(path) do
    case File.read(path) do
      {:ok, content} ->
        module_names = extract_module_names(content)

        if module_names == [] do
          []
        else
          base_analysis = %{
            path: path,
            app_name: extract_app_name(path, content),
            has_defstruct: String.contains?(content, "defstruct"),
            has_genserver: String.contains?(content, "use GenServer"),
            has_application: String.contains?(content, "use Application"),
            has_supervisor:
              String.contains?(content, "use Supervisor") or
                String.contains?(content, "Supervisor.start_link"),
            has_task:
              String.contains?(content, "use Task") or
                String.contains?(content, "Task.async"),
            has_agent: String.contains?(content, "use Agent"),
            has_start_link: String.contains?(content, "def start_link"),
            has_types: Regex.match?(~r/@type\s+/, content),
            has_specs: Regex.match?(~r/@spec\s+/, content),
            has_side_effects: detect_side_effects(content),
            function_count: count_functions(content)
          }

          Enum.map(module_names, fn module_name ->
            base_analysis
            |> Map.put(:module, module_name)
            |> Map.put(:boundary_keywords, detect_boundary_keywords_for_module(module_name, path))
          end)
        end

      {:error, _} ->
        []
    end
  end

  defp extract_module_names(content) do
    raw_names =
      Regex.scan(~r/defmodule\s+([A-Z][\w.]*)\s+do/, content)
      |> Enum.map(fn [_, name] -> name end)

    # Find the root module (has dots, likely top-level)
    root = Enum.find(raw_names, &String.contains?(&1, "."))

    # Qualify short names with the root prefix
    Enum.map(raw_names, fn name ->
      if String.contains?(name, ".") or is_nil(root) do
        name
      else
        root <> "." <> name
      end
    end)
    |> Enum.uniq()
  end

  defp detect_boundary_keywords_for_module(module_name, path) do
    boundary_words = ["Database", "Repo", "Store", "Client", "Adapter", "Gateway", "API"]
    path_name = Path.basename(path, ".ex")

    Enum.filter(boundary_words, fn word ->
      String.contains?(module_name, word) or String.contains?(path_name, word)
    end)
  end

  defp extract_app_name(path, content) do
    parts = Path.split(path)

    if "apps" in parts do
      idx = Enum.find_index(parts, &(&1 == "apps"))
      Enum.at(parts, idx + 1)
    else
      case Regex.run(~r/defmodule\s+([A-Z]\w*)\./, content) do
        [_, prefix] -> String.downcase(prefix)
        _ -> "app"
      end
    end
  end

  defp detect_side_effects(content) do
    side_effect_indicators = [
      "File.read",
      "File.write",
      "File.rm",
      "File.mkdir",
      "Database.",
      ":mnesia",
      "Req.",
      "HTTPoison",
      "GenServer.call",
      "GenServer.cast",
      "send(",
      "Port.",
      "System.cmd"
    ]

    Enum.any?(side_effect_indicators, &String.contains?(content, &1))
  end

  defp count_functions(content) do
    Regex.scan(~r/^\s+(?:def|defp|defmacro|defmacrop)\s+/m, content)
    |> length()
  end

  # --- Categorization ---

  defp categorize_data(analyses) do
    analyses
    |> Enum.filter(fn a -> a.has_defstruct end)
    |> Enum.filter(fn a ->
      # Data modules tend to have few functions and focus on struct definition
      a.function_count <= 15 or a.has_types
    end)
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp categorize_functional_core(analyses) do
    analyses
    |> Enum.filter(fn a ->
      # Pure functions, no GenServer, no side effects
      not a.has_genserver and
        not a.has_application and
        not a.has_supervisor and
        not a.has_side_effects and
        a.function_count > 0
    end)
    |> Enum.filter(fn a ->
      # Prefer modules with specs (indicates intentional API design)
      a.has_specs or a.function_count > 3
    end)
    |> Enum.reject(fn a ->
      # Exclude data-only modules
      a.has_defstruct and a.function_count <= 5
    end)
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  defp categorize_boundaries(analyses) do
    analyses
    |> Enum.filter(fn a -> a.boundary_keywords != [] end)
    |> Enum.map(fn a ->
      "#{a.module} (#{Enum.join(a.boundary_keywords, ", ")})"
    end)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp categorize_lifecycles(analyses) do
    analyses
    |> Enum.filter(fn a -> a.has_application or a.has_supervisor end)
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.take(6)
  end

  defp categorize_workers(analyses) do
    analyses
    |> Enum.filter(fn a ->
      a.has_genserver or a.has_task or a.has_agent or
        (a.has_start_link and not a.has_supervisor)
    end)
    |> Enum.map(& &1.module)
    |> Enum.uniq()
    |> Enum.take(8)
  end

  # --- Formatting ---

  defp format_modules([]), do: "none detected"
  defp format_modules(modules), do: Enum.join(modules, ", ")
end
