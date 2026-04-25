defmodule Llm.Client do
  @moduledoc false

  @base_url "http://127.0.0.1:8000"
  @request_options [
    receive_timeout: 360_000 * 2,
    connect_options: [timeout: 5_000]
  ]

  def chat(messages) when is_list(messages) do
    with {:ok, body} <- chat_raw(messages) do
      {:ok, get_in(body, ["choices", Access.at(0), "message", "content"])}
    end
  end

  def chat_raw(messages) when is_list(messages) do
    response =
      Req.post!(
        [
          url: "#{@base_url}/v1/chat/completions",
          json: %{
            model: "local-model",
            messages: messages,
            stream: false,
            max_tokens: 2048
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
end
