defmodule Llm.Client do
  @moduledoc false

  @base_url "http://127.0.0.1:8000"
  @request_options [
    receive_timeout: :infinity,
    connect_options: [timeout: 5_000]
  ]
  @chat_max_tokens 4_096

  def chat(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    with {:ok, body} <- chat_raw(messages, opts),
         {:ok, content} <-
           response_content(body, Keyword.get(opts, :max_tokens, @chat_max_tokens)) do
      {:ok, content}
    end
  end

  def chat_raw(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @chat_max_tokens)

    response =
      Req.post!(
        [
          url: "#{@base_url}/v1/chat/completions",
          json: %{
            model: "local-model",
            messages: messages,
            stream: false,
            max_tokens: max_tokens
          }
        ] ++ @request_options
      )

    {:ok, response.body}
  rescue
    error -> {:error, error}
  end

  def complete(prompt) when is_binary(prompt) do
    response =
      Req.post!(
        [
          url: "#{@base_url}/completion",
          json: %{
            prompt: prompt,
            n_predict: 256
          }
        ] ++ @request_options
      )

    {:ok, Map.get(response.body, "content")}
  rescue
    error -> {:error, error}
  end

  defp response_content(body, _max_tokens) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :missing_response_content}
      content -> {:ok, content}
    end
  end

  defp response_content(body, max_tokens) do
    content = chat_content(body)
    finish_reason = get_in(body, ["choices", Access.at(0), "finish_reason"])

    case {content, finish_reason} do
      {content, "length"} when is_binary(content) ->
        {:ok,
         content <>
           "\n\n[Response stopped because it reached the #{max_tokens}-token output limit. Ask a narrower follow-up or request the next part.]"}

      {content, _finish_reason} when is_binary(content) ->
        {:ok, content}

      {nil, _finish_reason} ->
        response_error(body)

      {_content, _finish_reason} ->
        {:error, :invalid_response_content}
    end
  end

  defp chat_content(body) when is_map(body) do
    [
      get_in(body, ["choices", Access.at(0), "message", "content"]),
      get_in(body, ["choices", Access.at(0), "text"]),
      get_in(body, ["choices", Access.at(0), "delta", "content"]),
      Map.get(body, "content"),
      Map.get(body, "response")
    ]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp chat_content(_body), do: nil

  defp response_error(%{"error" => %{"message" => message}}) when is_binary(message) do
    {:error, {:llm_server_error, message}}
  end

  defp response_error(%{"error" => error}) do
    {:error, {:llm_server_error, error}}
  end

  defp response_error(_body), do: {:error, :missing_response_content}
end
