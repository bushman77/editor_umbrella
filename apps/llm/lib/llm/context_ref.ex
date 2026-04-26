defmodule Llm.ContextRef do
  @moduledoc """
  A lightweight reference to contextual material that may be rehydrated into an
  LLM prompt later.

  Context refs let the app remember *what* was relevant without storing large
  file blobs directly in conversation history.
  """

  @enforce_keys [:type]
  defstruct [
    :type,
    :path,
    :module,
    :symbol,
    :summary,
    :chunk_id,
    :file_id,
    :start_line,
    :end_line,
    :sha256,
    :label,
    metadata: %{}
  ]

  @type ref_type ::
          :current_file
          | :selected_text
          | :file_summary
          | :file_chunk
          | :module_definition
          | :symbol_reference
          | :conversation_summary
          | :recent_message
          | :pinned_file

  @type t :: %__MODULE__{
          type: ref_type(),
          path: String.t() | nil,
          module: String.t() | nil,
          symbol: String.t() | nil,
          summary: String.t() | nil,
          chunk_id: String.t() | nil,
          file_id: String.t() | nil,
          start_line: pos_integer() | nil,
          end_line: pos_integer() | nil,
          sha256: String.t() | nil,
          label: String.t() | nil,
          metadata: map()
        }

  @spec new(ref_type(), keyword() | map()) :: t()
  def new(type, attrs \\ %{})

  def new(type, attrs) when is_list(attrs) do
    type
    |> base_ref()
    |> merge_attrs(Map.new(attrs))
  end

  def new(type, attrs) when is_map(attrs) do
    type
    |> base_ref()
    |> merge_attrs(attrs)
  end

  @spec line_range(t()) :: Range.t() | nil
  def line_range(%__MODULE__{start_line: start_line, end_line: end_line})
      when is_integer(start_line) and is_integer(end_line) do
    start_line..end_line
  end

  def line_range(_ref), do: nil

  @spec file_scoped?(t()) :: boolean()
  def file_scoped?(%__MODULE__{path: path}) when is_binary(path), do: true
  def file_scoped?(_ref), do: false

  @spec chunk_ref?(t()) :: boolean()
  def chunk_ref?(%__MODULE__{type: :file_chunk}), do: true
  def chunk_ref?(_ref), do: false

  @spec summary_ref?(t()) :: boolean()
  def summary_ref?(%__MODULE__{type: :file_summary}), do: true
  def summary_ref?(%__MODULE__{type: :conversation_summary}), do: true
  def summary_ref?(_ref), do: false

  @spec display_label(t()) :: String.t()
  def display_label(%__MODULE__{label: label}) when is_binary(label) and label != "", do: label

  def display_label(%__MODULE__{path: path, start_line: start_line, end_line: end_line})
      when is_binary(path) and is_integer(start_line) and is_integer(end_line) do
    "#{path}:#{start_line}-#{end_line}"
  end

  def display_label(%__MODULE__{path: path}) when is_binary(path), do: path
  def display_label(%__MODULE__{module: module}) when is_binary(module), do: module
  def display_label(%__MODULE__{type: type}), do: Atom.to_string(type)

  defp base_ref(type) do
    %__MODULE__{type: type}
  end

  defp merge_attrs(ref, attrs) do
    struct(ref, normalize_attrs(attrs))
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.into(%{})
    |> normalize_line_keys()
    |> normalize_metadata()
  end

  defp normalize_line_keys(attrs) do
    attrs
    |> maybe_put_integer(:start_line)
    |> maybe_put_integer(:end_line)
  end

  defp normalize_metadata(%{metadata: metadata} = attrs) when is_map(metadata), do: attrs
  defp normalize_metadata(attrs), do: Map.put(attrs, :metadata, %{})

  defp maybe_put_integer(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) ->
        attrs

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> Map.put(attrs, key, parsed)
          _ -> attrs
        end

      _ ->
        attrs
    end
  end
end
