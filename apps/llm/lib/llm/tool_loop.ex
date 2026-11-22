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
      |> Keyword.put_new(:max_tokens, @default_max_tokens)
      |> Keyword.put_new(:stop, Llm.ModelOutput.loop_stop_sequences())
      |> put_llm_chat_defaults()

    Llm.ToolRouter.with_workspace_root(Keyword.get(opts, :workspace_root), fn ->
      do_run(messages, opts, 0, max_rounds)
    end)
  end

  defp put_llm_chat_defaults(opts) do
    Enum.reduce(Llm.Sampling.keys(), opts, fn key, acc ->
      case Llm.Sampling.value(key) do
        nil -> acc
        value -> Keyword.put_new(acc, key, value)
      end
    end)
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
        handle_text_completion(messages, completion, content, opts, round, max_rounds)

      {:ok, completion} ->
        {:ok, completion}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The server returned text. It may be a final answer, or a tool call that
  # llama.cpp failed to parse (more common with low-bit quants).
  defp handle_text_completion(messages, completion, content, opts, round, max_rounds) do
    with true <- Llm.ModelOutput.tool_call_text?(content),
         {:ok, tool_calls} <- Llm.ModelOutput.parse_tool_calls(content) do
      Logger.warning("Model wrote #{length(tool_calls)} tool call(s) as text; executing them")

      text_completion = %{completion | message: nil, tool_calls: tool_calls}

      with {:ok, next_messages} <- append_tool_results(messages, text_completion, tool_calls) do
        do_run(next_messages, opts_after_tool_round(opts), round + 1, max_rounds)
      end
    else
      _not_a_tool_call -> final_answer(completion, content)
    end
  end

  defp final_answer(completion, content) do
    visible =
      content
      |> Llm.ModelOutput.strip_reasoning()
      |> Llm.ModelOutput.collapse_repetition()

    case visible do
      "" -> {:ok, completion}
      visible -> {:ok, visible}
    end
  end

  defp append_tool_results(messages, completion, tool_calls) do
    assistant_message = assistant_message_for_completion(completion)

    tool_messages =
      Enum.map(tool_calls, fn tool_call ->
        tool_call
        |> execute_tool_call()
        |> annotate_tool_result()
        |> tool_result_message(tool_call)
      end)

    {:ok, messages ++ [assistant_message] ++ tool_messages}
  rescue
    error -> {:error, error}
  end

  # Reasoning is never replayed: it burns context and the template re-adds
  # nothing useful from it on the next turn.
  defp assistant_message_for_completion(%{message: message}) when is_map(message) do
    message
    |> Map.drop(["reasoning_content", :reasoning_content])
    |> Map.update("content", nil, &strip_replayed_content/1)
  end

  defp assistant_message_for_completion(%{tool_calls: tool_calls}) do
    %{
      role: "assistant",
      content: "",
      tool_calls: Enum.map(tool_calls, & &1.raw)
    }
  end

  @failed_tool_note "This tool call failed. Tell the user which tool failed and the error " <>
                      "above. Do not answer from guesses or invent modules, files or " <>
                      "functions to fill the gap. You may retry with corrected arguments."

  @doc """
  Adds an instruction to failed tool results. Small models tend to treat a
  failed tool as permission to guess; a note right next to the error is far
  harder to ignore than a rule thousands of tokens earlier in the prompt.
  """
  @spec annotate_tool_result(map()) :: map()
  def annotate_tool_result(%{ok: false} = result), do: Map.put(result, :note, @failed_tool_note)
  def annotate_tool_result(result) when is_map(result), do: result

  defp strip_replayed_content(content) when is_binary(content),
    do: Llm.ModelOutput.strip_reasoning(content)

  defp strip_replayed_content(content), do: content

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

  # Tool results are capped so one large file read cannot overflow the
  # model's context window (editor_read_file allows up to 200 KB).
  defp tool_result_message(result, tool_call) do
    tool_call
    |> Llm.Client.tool_result_message(result)
    |> Map.update!(:content, &Llm.Budget.truncate(&1, Llm.Budget.tool_result_char_limit()))
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

  @doc """
  The message sent when the tool-round limit is hit. It repeats the user's
  original question: after several rounds of tool results the question is
  thousands of characters back, and small models otherwise answer whatever
  they were investigating last instead of what was asked.
  """
  @spec final_answer_instruction([message()], pos_integer()) :: String.t()
  def final_answer_instruction(messages, max_rounds) when is_list(messages) do
    question_section =
      case original_question(messages) do
        nil -> ""
        question -> "\nThe question you must answer:\n#{question}\n"
      end

    """
    Stop using tools now.

    You have reached the maximum tool-call round limit of #{max_rounds}.
    #{question_section}
    Answer that question directly, using only the tool results and conversation context already available.
    If the gathered context is incomplete, say exactly what is missing.
    """
  end

  @question_marker "User question:"
  @max_question_chars 1_500

  @doc """
  The question from the latest user message. Editor requests put context first
  and the question after a `User question:` line; for those only the question
  is returned. Plain prompts are returned whole. Capped at 1,500 characters.
  """
  @spec original_question([message()]) :: String.t() | nil
  def original_question(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn message ->
      if message_role(message) == "user", do: message_content(message)
    end)
    |> question_text()
  end

  defp question_text(content) when is_binary(content) do
    question =
      case String.split(content, @question_marker) do
        [_only] -> content
        parts -> List.last(parts)
      end
      |> String.trim()

    cond do
      question == "" ->
        nil

      String.length(question) > @max_question_chars ->
        String.slice(question, 0, @max_question_chars)

      true ->
        question
    end
  end

  defp question_text(_content), do: nil

  defp message_role(message), do: Map.get(message, :role) || Map.get(message, "role")
  defp message_content(message), do: Map.get(message, :content) || Map.get(message, "content")

  defp finalize_from_context(messages, opts, max_rounds) do
    final_messages =
      messages ++
        [
          %{
            role: "user",
            content: final_answer_instruction(messages, max_rounds)
          }
        ]

    final_opts =
      opts
      |> Keyword.drop([:tools, :tool_choice])
      |> Keyword.put(:max_tokens, Keyword.get(opts, :max_tokens, 1_024))

    case Llm.Client.chat_completion(final_messages, final_opts) do
      {:ok, %{content: content} = completion} when is_binary(content) ->
        final_answer(completion, content)

      {:ok, completion} ->
        {:ok, completion}

      {:error, reason} ->
        {:error, {:max_tool_rounds_exceeded, max_rounds, reason}}
    end
  end
end
