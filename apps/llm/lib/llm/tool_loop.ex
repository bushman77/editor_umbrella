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
    case Llm.Client.chat_completion(messages, opts) do
      {:ok, %{tool_calls: [_ | _] = tool_calls} = completion} ->
        Logger.debug("Qwen requested #{length(tool_calls)} tool call(s)")

        with {:ok, next_messages} <- append_tool_results(messages, completion, tool_calls) do
          do_run(next_messages, opts, round + 1, max_rounds)
        end

      {:ok, %{content: content} = completion} when is_binary(content) ->
        case String.trim(content) do
          "" -> {:ok, completion}
          _ -> {:ok, content}
        end

      {:ok, completion} ->
        {:ok, completion}

      {:error, reason} ->
        {:error, reason}
    end
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
