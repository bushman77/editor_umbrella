defmodule Llm.ProjectMemory.FileChunk do
  @moduledoc """
  A searchable fragment of a project file.

  File chunks let the app retrieve exact code ranges without having to inject
  entire files into every LLM request.
  """

  alias Llm.ContextRef

  @enforce_keys [:path, :chunk_index, :start_line, :end_line, :content, :sha256]
  defstruct [
    :id,
    :file_id,
    :path,
    :chunk_index,
    :start_line,
    :end_line,
    :content,
    :summary,
    :sha256,
    :language,
    :symbols,
    :module_names,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          file_id: String.t() | nil,
          path: String.t(),
          chunk_index: non_neg_integer(),
          start_line: pos_integer(),
          end_line: pos_integer(),
          content: String.t(),
          summary: String.t() | nil,
          sha256: String.t(),
          language: String.t() | nil,
          symbols: [String.t()],
          module_names: [String.t()],
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
    path = Map.fetch!(attrs, :path)
    content = Map.fetch!(attrs, :content)

    %__MODULE__{
      id: Map.get(attrs, :id),
      file_id: Map.get(attrs, :file_id),
      path: path,
      chunk_index: Map.fetch!(attrs, :chunk_index),
      start_line: Map.fetch!(attrs, :start_line),
      end_line: Map.fetch!(attrs, :end_line),
      content: content,
      summary: Map.get(attrs, :summary),
      sha256: Map.get(attrs, :sha256, sha256(content)),
      language: Map.get(attrs, :language, infer_language(path)),
      symbols: normalize_symbols(Map.get(attrs, :symbols, [])),
      module_names: Map.get(attrs, :module_names, []),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @spec from_lines(String.t(), [String.t()], non_neg_integer(), keyword() | map()) :: t()
  def from_lines(path, lines, chunk_index, attrs \\ %{})

  def from_lines(path, lines, chunk_index, attrs)
      when is_binary(path) and is_list(lines) and is_integer(chunk_index) and chunk_index >= 0 and
             is_list(attrs) do
    from_lines(path, lines, chunk_index, Map.new(attrs))
  end

  def from_lines(path, lines, chunk_index, attrs)
      when is_binary(path) and is_list(lines) and is_integer(chunk_index) and chunk_index >= 0 and
             is_map(attrs) do
    start_line = Map.get(attrs, :start_line, 1)
    end_line = Map.get(attrs, :end_line, start_line + max(length(lines) - 1, 0))
    content = Enum.join(lines, "\n")

    new(
      attrs
      |> Map.put(:path, path)
      |> Map.put(:chunk_index, chunk_index)
      |> Map.put(:start_line, start_line)
      |> Map.put(:end_line, end_line)
      |> Map.put(:content, content)
      |> Map.put_new(:language, infer_language(path))
    )
  end

  @spec to_context_ref(t()) :: ContextRef.t()
  def to_context_ref(%__MODULE__{} = chunk) do
    ContextRef.new(:file_chunk,
      path: chunk.path,
      chunk_id: chunk.id,
      file_id: chunk.file_id,
      start_line: chunk.start_line,
      end_line: chunk.end_line,
      sha256: chunk.sha256,
      summary: chunk.summary,
      label: display_label(chunk),
      metadata: %{
        chunk_index: chunk.chunk_index,
        language: chunk.language,
        symbols: chunk.symbols,
        module_names: chunk.module_names
      }
    )
  end

  @spec line_count(t()) :: pos_integer()
  def line_count(%__MODULE__{start_line: start_line, end_line: end_line}) do
    max(end_line - start_line + 1, 1)
  end

  @spec display_label(t()) :: String.t()
  def display_label(%__MODULE__{path: path, start_line: start_line, end_line: end_line}) do
    "#{path}:#{start_line}-#{end_line}"
  end

  @spec stale?(t(), String.t()) :: boolean()
  def stale?(%__MODULE__{sha256: stored_sha}, current_sha) when is_binary(current_sha) do
    stored_sha != current_sha
  end

  @spec update_summary(t(), String.t()) :: t()
  def update_summary(%__MODULE__{} = chunk, summary) when is_binary(summary) do
    %{chunk | summary: summary}
  end

  @spec update_symbols(t(), [String.t()] | [atom()]) :: t()
  def update_symbols(%__MODULE__{} = chunk, symbols) when is_list(symbols) do
    %{chunk | symbols: normalize_symbols(symbols)}
  end

  @spec update_module_names(t(), [String.t()]) :: t()
  def update_module_names(%__MODULE__{} = chunk, module_names) when is_list(module_names) do
    %{chunk | module_names: Enum.uniq(module_names)}
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

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
