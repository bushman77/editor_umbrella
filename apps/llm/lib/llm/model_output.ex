defmodule Llm.ModelOutput do
  @moduledoc """
  Pure helpers for cleaning up raw model output.

  Local Qwen models served by llama.cpp occasionally leak things into the
  `content` field that should have been parsed out by the server:

    * reasoning blocks (`<think>...</think>`), or a bare `...</think>` tail when
      the chat template opened the block in the prompt
    * tool calls written as text instead of structured `tool_calls`

  Tool calls are recognised in three shapes:

    * Qwen3.5/3.6 / Qwen3-Coder XML:
      `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>`
    * Hermes-style JSON inside tags: `<tool_call>{"name": ..., "arguments": ...}</tool_call>`
    * a bare JSON object on one line with `"name"` and `"arguments"` keys
  """

  @type tool_call :: %{
          id: String.t(),
          type: String.t(),
          name: String.t(),
          arguments: map(),
          raw: map()
        }

  @think_block ~r/<think>.*?<\/think>/s
  @xml_function ~r/<function=([^>\s]+)\s*>(.*?)<\/function>/s
  @xml_parameter ~r/<parameter=([^>\s]+)\s*>(.*?)<\/parameter>/s
  @tagged_json ~r/<tool_call>\s*(\{.*?\})\s*<\/tool_call>/s

  @doc """
  Removes reasoning blocks and returns the visible answer, trimmed.

  An unterminated `<think>` means the model ran out of tokens while reasoning,
  so nothing visible remains and `""` is returned.
  """
  @spec strip_reasoning(String.t() | nil) :: String.t()
  def strip_reasoning(nil), do: ""

  def strip_reasoning(text) when is_binary(text) do
    text = Regex.replace(@think_block, text, "")

    text =
      case String.split(text, "</think>") do
        [only] -> only
        parts -> List.last(parts)
      end

    text =
      case String.split(text, "<think>", parts: 2) do
        [before, _unterminated] -> before
        [only] -> only
      end

    String.trim(text)
  end

  # Strings that only ever appear once the model has finished answering and
  # started looping on restatements and check marks. Sent as `stop` so
  # llama-server ends generation right there instead of running to max_tokens.
  @loop_stop_sequences ["✅✅✅", "✅ ✅ ✅", "--- Final", "--- ✅", "--- End of Response"]

  # Repetition loops that still get through:
  #   * a symbol or emoji repeated 20+ times, with or without spaces ("✅✅✅")
  #   * any short token repeated 20+ times separated by whitespace ("done done")
  # 20 repeats never happens in a real answer.
  @symbol_loop ~r/(\p{So}\x{FE0F}?)(?:\s*\1){19,}/u
  @spaced_loop ~r/(\S{1,12})(?:\s+\1){19,}/u

  @doc "Stop sequences that end a looping answer early."
  @spec loop_stop_sequences() :: [String.t()]
  def loop_stop_sequences, do: @loop_stop_sequences

  @doc """
  Collapses a degenerate repetition loop (the same symbol or short token 20+
  times in a row) down to a single occurrence, then trims. Other text is left
  alone.
  """
  @spec collapse_repetition(String.t()) :: String.t()
  def collapse_repetition(text) when is_binary(text) do
    text = Regex.replace(@symbol_loop, text, "\\1")

    @spaced_loop
    |> Regex.replace(text, "\\1")
    |> String.trim()
  end

  @doc "True when text looks like a tool call the server failed to parse."
  @spec tool_call_text?(String.t() | nil) :: boolean()
  def tool_call_text?(text) when is_binary(text) do
    String.contains?(text, "<tool_call>") or
      Regex.match?(@xml_function, text) or
      (String.contains?(text, "\"name\"") and String.contains?(text, "\"arguments\""))
  end

  def tool_call_text?(_text), do: false

  @doc """
  Parses tool calls written as text. Returns `{:ok, calls}` with at least one
  call, or `:error` when nothing usable is found.
  """
  @spec parse_tool_calls(String.t() | nil) :: {:ok, [tool_call()]} | :error
  def parse_tool_calls(text) when is_binary(text) do
    calls =
      case xml_calls(text) do
        [] -> tagged_json_calls(text)
        calls -> calls
      end

    calls =
      case calls do
        [] -> json_line_calls(text)
        calls -> calls
      end

    case calls do
      [] -> :error
      calls -> {:ok, calls}
    end
  end

  def parse_tool_calls(_text), do: :error

  # -- XML (Qwen3.5/3.6, Qwen3-Coder) ----------------------------------------

  defp xml_calls(text) do
    @xml_function
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [name, body] ->
      arguments =
        @xml_parameter
        |> Regex.scan(body, capture: :all_but_first)
        |> Map.new(fn [key, value] -> {key, xml_value(value)} end)

      build_call(name, arguments)
    end)
  end

  # Values arrive as raw text. Keep strings as strings, but decode numbers,
  # booleans, lists and objects so `max_bytes: 4000` reaches tools as an integer.
  defp xml_value(value) do
    value = value |> String.trim_leading("\n") |> String.trim_trailing("\n")

    case Jason.decode(value) do
      {:ok, decoded} when not is_binary(decoded) and not is_nil(decoded) -> decoded
      _other -> value
    end
  end

  # -- <tool_call>{json}</tool_call> (Hermes / Qwen2.5 / Qwen3) ----------------

  defp tagged_json_calls(text) do
    @tagged_json
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.flat_map(fn [json] ->
      case decode_json(json) do
        {:ok, decoded} -> call_from_decoded(decoded)
        :error -> []
      end
    end)
  end

  # -- bare JSON line ---------------------------------------------------------

  # Starts at the first line naming both keys and reads to the end of the
  # text, so multi-line values (such as Elixir heredocs) are captured.
  defp json_line_calls(text) do
    lines = String.split(text, "\n")

    lines
    |> Enum.find_index(
      &(String.contains?(&1, "\"name\"") and String.contains?(&1, "\"arguments\""))
    )
    |> case do
      nil ->
        []

      index ->
        candidate = lines |> Enum.drop(index) |> Enum.join("\n")

        with [match] <- Regex.run(~r/\{.*\}/s, candidate),
             {:ok, decoded} <- decode_json(match) do
          call_from_decoded(decoded)
        else
          _other -> []
        end
    end
  end

  defp call_from_decoded(%{"name" => name, "arguments" => arguments}) when is_binary(name) do
    case normalize_arguments(arguments) do
      {:ok, arguments} -> [build_call(name, arguments)]
      :error -> []
    end
  end

  defp call_from_decoded(_decoded), do: []

  defp normalize_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> :error
    end
  end

  defp normalize_arguments(_arguments), do: :error

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _reason} ->
        case Jason.decode(fix_elixir_triple_quotes(json)) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _reason} -> :error
        end
    end
  end

  # Models sometimes write Elixir heredocs (`"""...""") inside JSON values.
  defp fix_elixir_triple_quotes(json) do
    Regex.replace(~r/:\s*"""(.*?)"""/s, json, fn _full, content ->
      escaped =
        content
        |> String.trim()
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")
        |> String.replace("\n", "\\n")
        |> String.replace("\r", "\\r")
        |> String.replace("\t", "\\t")

      ": \"#{escaped}\""
    end)
  end

  # `raw` uses the OpenAI wire shape so the call can be replayed to the server
  # as an assistant `tool_calls` entry that matches the tool result message.
  defp build_call(name, arguments) do
    id = "text_call_#{System.unique_integer([:positive])}"

    %{
      id: id,
      type: "function",
      name: name,
      arguments: arguments,
      raw: %{
        "id" => id,
        "type" => "function",
        "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
      }
    }
  end
end
