defmodule Llm.ContextPack do
  @moduledoc """
  A compact, request-ready bundle of context assembled for an LLM interaction.

  The context pack is the boundary between app-managed memory and the prompt
  actually sent to the model.
  """

  alias Llm.ContextRef
  alias Llm.Prompts

  @enforce_keys [:messages]
  defstruct [
    :conversation_id,
    :project_id,
    :question,
    :current_file,
    :selection,
    :estimated_tokens,
    :token_budget,
    messages: [],
    refs: [],
    summaries: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          conversation_id: String.t() | nil,
          project_id: String.t() | nil,
          question: String.t() | nil,
          current_file: String.t() | nil,
          selection: map() | nil,
          estimated_tokens: non_neg_integer() | nil,
          token_budget: pos_integer() | nil,
          messages: Prompts.messages(),
          refs: [ContextRef.t()],
          summaries: [String.t()],
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
      conversation_id: Map.get(attrs, :conversation_id),
      project_id: Map.get(attrs, :project_id),
      question: Map.get(attrs, :question),
      current_file: Map.get(attrs, :current_file),
      selection: Map.get(attrs, :selection),
      estimated_tokens: Map.get(attrs, :estimated_tokens),
      token_budget: Map.get(attrs, :token_budget),
      messages: Map.get(attrs, :messages, []),
      refs: normalize_refs(Map.get(attrs, :refs, [])),
      summaries: Map.get(attrs, :summaries, []),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  @spec put_messages(t(), Prompts.messages()) :: t()
  def put_messages(%__MODULE__{} = pack, messages) when is_list(messages) do
    %{pack | messages: messages}
  end

  @spec add_ref(t(), ContextRef.t() | map() | keyword()) :: t()
  def add_ref(%__MODULE__{} = pack, %ContextRef{} = ref) do
    %{pack | refs: pack.refs ++ [ref]}
  end

  def add_ref(%__MODULE__{} = pack, ref_attrs) when is_map(ref_attrs) or is_list(ref_attrs) do
    add_ref(pack, ContextRef.new(:file_chunk, ref_attrs))
  end

  @spec add_refs(t(), [ContextRef.t() | map() | keyword()]) :: t()
  def add_refs(%__MODULE__{} = pack, refs) when is_list(refs) do
    Enum.reduce(refs, pack, fn ref, acc -> add_ref(acc, ref) end)
  end

  @spec add_summary(t(), String.t()) :: t()
  def add_summary(%__MODULE__{} = pack, summary) when is_binary(summary) do
    %{pack | summaries: pack.summaries ++ [summary]}
  end

  @spec put_estimated_tokens(t(), non_neg_integer()) :: t()
  def put_estimated_tokens(%__MODULE__{} = pack, tokens)
      when is_integer(tokens) and tokens >= 0 do
    %{pack | estimated_tokens: tokens}
  end

  @spec put_token_budget(t(), pos_integer()) :: t()
  def put_token_budget(%__MODULE__{} = pack, token_budget)
      when is_integer(token_budget) and token_budget > 0 do
    %{pack | token_budget: token_budget}
  end

  @spec with_metadata(t(), map()) :: t()
  def with_metadata(%__MODULE__{} = pack, metadata) when is_map(metadata) do
    %{pack | metadata: Map.merge(pack.metadata, metadata)}
  end

  @spec referenced_paths(t()) :: [String.t()]
  def referenced_paths(%__MODULE__{} = pack) do
    pack.refs
    |> Enum.map(& &1.path)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{} = pack) do
    length(pack.messages)
  end

  @spec ref_count(t()) :: non_neg_integer()
  def ref_count(%__MODULE__{} = pack) do
    length(pack.refs)
  end

  @spec within_budget?(t()) :: boolean()
  def within_budget?(%__MODULE__{token_budget: nil}), do: true

  def within_budget?(%__MODULE__{estimated_tokens: nil}), do: true

  def within_budget?(%__MODULE__{estimated_tokens: estimated, token_budget: budget})
      when is_integer(estimated) and is_integer(budget) do
    estimated <= budget
  end

  @spec to_prompt_input(t()) :: %{
          messages: Prompts.messages(),
          refs: [ContextRef.t()],
          metadata: map()
        }
  def to_prompt_input(%__MODULE__{} = pack) do
    %{
      messages: pack.messages,
      refs: pack.refs,
      metadata:
        Map.merge(pack.metadata, %{
          conversation_id: pack.conversation_id,
          project_id: pack.project_id,
          current_file: pack.current_file,
          estimated_tokens: pack.estimated_tokens,
          token_budget: pack.token_budget
        })
    }
  end

  defp normalize_refs(refs) do
    Enum.map(refs, fn
      %ContextRef{} = ref -> ref
      attrs when is_map(attrs) -> ContextRef.new(:file_chunk, attrs)
      attrs when is_list(attrs) -> ContextRef.new(:file_chunk, attrs)
    end)
  end
end
