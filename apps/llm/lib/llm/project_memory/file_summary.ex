defmodule Llm.ProjectMemory.FileSummary do
  @moduledoc """
  Compact metadata and summary for a project file.

  File summaries are used for orientation and retrieval without forcing the app
  to inject full file contents into every prompt.
  """

  alias Llm.ContextRef

  @enforce_keys [:path, :sha256]
  defstruct [
    :path,
    :language,
    :sha256,
    :summary,
    :symbols,
    :module_names,
    :last_seen_at,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          language: String.t() | nil,
          sha256: String.t(),
          summary: String.t() | nil,
          symbols: [String.t()] | [atom()],
          module_names: [String.t()],
          last_seen_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{})

  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      path: Map.fetch!(attrs, :path),
      language: Map.get(attrs, :language, infer_language(Map.fetch!(attrs, :path))),
      sha256: Map.fetch!(attrs, :sha256),
      summary: Map.get(attrs, :summary),
      symbols: normalize_symbols(Map.get(attrs, :symbols, [])),
      module_names: Map.get(attrs, :module_names, []),
      last_seen_at: normalize_datetime(Map.get(attrs, :last_seen_at)),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @spec from_file(String.t(), keyword() | map()) :: t()
  def from_file(path, attrs \\ %{})

  def from_file(path, attrs) when is_binary(path) and is_list(attrs) do
    from_file(path, Map.new(attrs))
  end

  def from_file(path, attrs) when is_binary(path) and is_map(attrs) do
    sha256 =
      attrs[:sha256] ||
        path
        |> File.read!()
        |> sha256()

    new(
      attrs
      |> Map.put(:path, path)
      |> Map.put(:sha256, sha256)
      |> Map.put_new(:language, infer_language(path))
    )
  end

  @spec to_context_ref(t()) :: ContextRef.t()
  def to_context_ref(%__MODULE__{} = summary) do
    ContextRef.new(:file_summary,
      path: summary.path,
      summary: summary.summary,
      sha256: summary.sha256,
      module: List.first(summary.module_names),
      label: summary.path,
      metadata: %{
        language: summary.language,
        symbols: summary.symbols,
        module_names: summary.module_names,
        last_seen_at: summary.last_seen_at
      }
    )
  end

  @spec display_summary(t()) :: String.t()
  def display_summary(%__MODULE__{summary: summary, path: path})
      when is_binary(summary) and summary != "" do
    "#{path} — #{summary}"
  end

  def display_summary(%__MODULE__{path: path}), do: path

  @spec stale?(t(), String.t()) :: boolean()
  def stale?(%__MODULE__{sha256: stored_sha}, current_sha) when is_binary(current_sha) do
    stored_sha != current_sha
  end

  @spec update_summary(t(), String.t()) :: t()
  def update_summary(%__MODULE__{} = file_summary, summary) when is_binary(summary) do
    %{file_summary | summary: summary}
  end

  @spec update_symbols(t(), [String.t()] | [atom()]) :: t()
  def update_symbols(%__MODULE__{} = file_summary, symbols) when is_list(symbols) do
    %{file_summary | symbols: normalize_symbols(symbols)}
  end

  @spec update_module_names(t(), [String.t()]) :: t()
  def update_module_names(%__MODULE__{} = file_summary, module_names)
      when is_list(module_names) do
    %{file_summary | module_names: Enum.uniq(module_names)}
  end

  @spec touch(t(), DateTime.t() | nil) :: t()
  def touch(%__MODULE__{} = file_summary, datetime \\ DateTime.utc_now()) do
    %{file_summary | last_seen_at: normalize_datetime(datetime)}
  end

  @spec infer_language(String.t()) :: String.t()
  def infer_language(path) when is_binary(path) do
    case Path.extname(path) do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "heex"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "tsx"
      ".json" -> "json"
      ".md" -> "markdown"
      _ -> "text"
    end
  end

  defp normalize_symbols(symbols) do
    symbols
    |> Enum.map(fn
      symbol when is_atom(symbol) -> Atom.to_string(symbol)
      symbol when is_binary(symbol) -> symbol
    end)
    |> Enum.uniq()
  end

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = dt), do: dt

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp normalize_datetime(_value), do: nil

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
