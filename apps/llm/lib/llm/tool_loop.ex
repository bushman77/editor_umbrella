defmodule Llm.ToolLoop do
  @moduledoc """
  Runs a bounded local Qwen tool-call loop.

  Flow:

    1. Send messages + tool definitions to Qwen.
    2. If Qwen returns final content, return it.
    3. If Qwen returns tool calls, execute only whitelisted tools.
    4. Append assistant tool-call message and tool result messages.
    5. Send the updated conversation back to Qwen.
    6. Repeat until final content or max tool rounds is reached.

  This module does not directly know about editor files yet. Editor-specific
  tools should be added behind `Llm.ToolRouter`.
  """

  require Logger

  @default_max_rounds 4
  @default_temperature 0.1
  @default_max_tokens 1_024

  @type message :: map()
  @type run_result ::
          {:ok, String.t()}
          | {:ok, map()}
          | {:error, term()}

  @spec run([message()], keyword()) :: run_result()
  def run(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    max_rounds = Keyword.get(opts, :max_tool_rounds, @default_max_rounds)

    opts =
      opts
      |> Keyword.put_new(:tools, Llm.ToolRouter.tools())
      |> Keyword.put_new(:tool_choice, "auto")
      |> Keyword.put_new(:temperature, @default_temperature)
      |> Keyword.put_new(:max_tokens, @default_max_tokens)

    do_run(messages, opts, 0, max_rounds)
  end

  @spec run_text(String.t(), keyword()) :: run_result()
  def run_text(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    run([%{role: "user", content: prompt}], opts)
  end

  defp do_run(messages, opts, round, max_rounds) when round >= max_rounds do
    Logger.warning("Max tool rounds reached; forcing final no-tool answer")
    finalize_from_context(messages, opts, max_rounds)
  end

  defp do_run(messages, opts, round, max_rounds) do
    Logger.debug(
      "ToolLoop round=#{round}/#{max_rounds} " <>
        "tool_choice=#{inspect(Keyword.get(opts, :tool_choice))} " <>
        "tools=#{length(Keyword.get(opts, :tools, []))} " <>
        "messages=#{length(messages)}"
    )

    case Llm.Client.chat_completion(messages, opts) do
      {:ok, %{tool_calls: [_ | _] = tool_calls} = completion} ->
        Logger.debug("Qwen requested #{length(tool_calls)} tool call(s)")

        with {:ok, next_messages} <- append_tool_results(messages, completion, tool_calls) do
          do_run(next_messages, opts_after_tool_round(opts), round + 1, max_rounds)
        end

      {:ok, %{content: content} = completion} when is_binary(content) ->
        trimmed = String.trim(content)

        if looks_like_tool_call_text?(trimmed) do
          Logger.warning(
            "Model returned tool-call-shaped text. Attempting to parse and execute..."
          )

          case parse_tool_call_from_text(trimmed) do
            {:ok, tool_call} ->
              # We parsed the JSON! Construct a fake completion so append_tool_results works
              fake_completion = %{completion | tool_calls: [tool_call]}

              with {:ok, next_messages} <-
                     append_tool_results(messages, fake_completion, [tool_call]) do
                do_run(next_messages, opts_after_tool_round(opts), round + 1, max_rounds)
              end

            :error ->
              # Parsing failed, just return the text as a normal response
              case trimmed do
                "" -> {:ok, completion}
                _ -> {:ok, content}
              end
          end
        else
          # Normal text response
          case trimmed do
            "" -> {:ok, completion}
            _ -> {:ok, content}
          end
        end

      {:ok, completion} ->
        {:ok, completion}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_tool_call_from_text(content) do
    content
    |> String.split("\n")
    |> Enum.find(fn line ->
      String.contains?(line, "\"name\"") and String.contains?(line, "\"arguments\"")
    end)
    |> case do
      nil ->
        :error

      line ->
        case Regex.run(~r/\{.*\}/s, line) do
          [match] ->
            case Jason.decode(match) do
              {:ok, decoded} ->
                build_tool_call_from_parsed(decoded)

              {:error, _reason} ->
                fixed_json = fix_elixir_triple_quotes(match)

                case Jason.decode(fixed_json) do
                  {:ok, decoded} -> build_tool_call_from_parsed(decoded)
                  {:error, _} -> :error
                end
            end

          nil ->
            :error
        end
    end
  end

  defp build_tool_call_from_parsed(decoded) do
    with %{"name" => name, "arguments" => args} <- decoded do
      {:ok,
       %{
         id: "text_call_#{System.unique_integer([:positive])}",
         type: "function",
         name: name,
         arguments: args,
         raw: decoded
       }}
    else
      _ -> :error
    end
  end

  defp fix_elixir_triple_quotes(json) do
    # Replace Elixir """...""" with properly escaped JSON strings
    # Pattern: : """ content """
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

  defp looks_like_tool_call_text?(content) do
    String.contains?(content, "\"name\"") and
      String.contains?(content, "\"arguments\"")
  end

  defp append_tool_results(messages, completion, tool_calls) do
    assistant_message = assistant_message_for_completion(completion)

    tool_messages =
      Enum.map(tool_calls, fn tool_call ->
        tool_call
        |> execute_tool_call()
        |> tool_result_message(tool_call)
      end)

    {:ok, messages ++ [assistant_message] ++ tool_messages}
  rescue
    error -> {:error, error}
  end

  defp assistant_message_for_completion(%{message: message}) when is_map(message) do
    message
  end

  defp assistant_message_for_completion(%{tool_calls: tool_calls}) do
    %{
      role: "assistant",
      content: "",
      tool_calls: Enum.map(tool_calls, & &1.raw)
    }
  end

  defp execute_tool_call(%{name: name, arguments: arguments}) do
    Logger.debug("Executing tool #{name} with arguments=#{inspect(arguments)}")

    case Llm.ToolRouter.call(name, arguments) do
      {:ok, result} ->
        %{
          ok: true,
          result: result
        }

      {:error, error} ->
        %{
          ok: false,
          error: error
        }
    end
  rescue
    error ->
      %{
        ok: false,
        error: %{
          error: "tool_execution_exception",
          message: Exception.message(error),
          exception: inspect(error)
        }
      }
  end

  defp tool_result_message(result, tool_call) do
    Llm.Client.tool_result_message(tool_call, result)
  end

  defp opts_after_tool_round(opts) do
    case Keyword.get(opts, :tool_choice) do
      "required" ->
        Keyword.put(opts, :tool_choice, "auto")

      %{} ->
        Keyword.put(opts, :tool_choice, "auto")

      _ ->
        opts
    end
  end

  defp finalize_from_context(messages, opts, max_rounds) do
    final_messages =
      messages ++
        [
          %{
            role: "user",
            content: """
            Stop using tools now.

            You have reached the maximum tool-call round limit of #{max_rounds}.

            Give the best final answer you can using only the tool results and conversation context already available.
            If the gathered context is incomplete, say exactly what is missing.
            """
          }
        ]

    final_opts =
      opts
      |> Keyword.drop([:tools, :tool_choice])
      |> Keyword.put(:max_tokens, Keyword.get(opts, :max_tokens, 1_024))

    case Llm.Client.chat_completion(final_messages, final_opts) do
      {:ok, %{content: content}} when is_binary(content) ->
        {:ok, content}

      {:ok, completion} ->
        {:ok, completion}

      {:error, reason} ->
        {:error, {:max_tool_rounds_exceeded, max_rounds, reason}}
    end
  end
end
