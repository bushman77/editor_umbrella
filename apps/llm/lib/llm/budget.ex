defmodule Llm.Budget do
  @moduledoc """
  Pure prompt-size budgeting derived from the active model profile.

  Everything is measured in characters because that is what callers slice.
  Source code averages roughly 3-4 characters per token, so `@chars_per_token`
  stays on the conservative side: overshooting the context window makes
  llama-server reject the whole request, undershooting only trims context.

  Config keys read from `:llm` (all optional):

    * `:context_size` - the llama-server `--ctx-size`
    * `:max_tokens` - output tokens to reserve when the caller passes none
    * `:prompt_overhead_tokens` - system rules + tool schemas (default 3_000)
    * `:tool_result_max_chars` - explicit cap for one tool result
  """

  @chars_per_token 3
  @default_context_size 32_768
  @default_max_tokens 4_096
  @default_overhead_tokens 3_000
  @min_prompt_chars 4_000
  @min_tool_result_chars 2_000

  @doc """
  Characters available for variable prompt content (open buffers, retrieved
  files, tool results) after reserving room for the answer and fixed overhead.

  Options: `:context_size`, `:max_tokens`, `:overhead_tokens`. Missing options
  fall back to `:llm` config.
  """
  @spec prompt_char_budget(keyword()) :: pos_integer()
  def prompt_char_budget(opts \\ []) do
    context = option(opts, :context_size, :context_size, @default_context_size)
    output = option(opts, :max_tokens, :max_tokens, @default_max_tokens)
    overhead = option(opts, :overhead_tokens, :prompt_overhead_tokens, @default_overhead_tokens)

    # A huge configured n_predict (e.g. 16k on a 49k window) must not starve
    # the prompt, so never reserve more than half the window for output.
    reserved = min(output, div(context, 2))

    max((context - reserved - overhead) * @chars_per_token, @min_prompt_chars)
  end

  @doc """
  Maximum characters for a single tool result fed back to the model.
  Defaults to a third of the prompt budget so a few tool rounds still fit.
  """
  @spec tool_result_char_limit(keyword()) :: pos_integer()
  def tool_result_char_limit(opts \\ []) do
    case Application.get_env(:llm, :tool_result_max_chars) do
      limit when is_integer(limit) and limit > 0 ->
        limit

      _other ->
        opts
        |> prompt_char_budget()
        |> div(3)
        |> max(@min_tool_result_chars)
    end
  end

  @doc """
  Truncates `text` to `max_chars`, appending a marker that tells the model
  the content was cut so it can request a narrower read.
  """
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, max_chars)
      when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    length = String.length(text)

    if length > max_chars do
      String.slice(text, 0, max_chars) <>
        "\n\n[truncated #{length - max_chars} of #{length} characters to fit the model's " <>
        "context window; search for the specific part you need instead of reading it all]"
    else
      text
    end
  end

  defp option(opts, key, config_key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        case Application.get_env(:llm, config_key) do
          value when is_integer(value) and value > 0 -> value
          _other -> default
        end
    end
  end
end
