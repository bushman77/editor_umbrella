defmodule Llm.Client do
  @moduledoc false

  @chat_max_tokens 8_192

  @type chat_message :: map()
  @type response_body :: map() | String.t()

  @type tool_call :: %{
          required(:id) => String.t() | nil,
          required(:type) => String.t(),
          required(:name) => String.t(),
          required(:arguments) => map(),
          required(:raw) => map()
        }

  @type chat_completion :: %{
          required(:content) => String.t() | nil,
          required(:finish_reason) => String.t() | nil,
          required(:tool_calls) => [tool_call()],
          required(:message) => map() | nil,
          required(:raw) => response_body()
        }

  @optional_body_opts [
    :temperature,
    :top_p,
    :top_k,
    :min_p,
    :repeat_penalty,
    :seed,
    :stop,
    :response_format
  ]

  @spec chat([chat_message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @chat_max_tokens)

    with {:ok, completion} <- chat_completion(messages, opts) do
      completion_content(completion, max_tokens)
    end
  end

  @spec chat_completion([chat_message()], keyword()) ::
          {:ok, chat_completion()} | {:error, term()}
  def chat_completion(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    with {:ok, body} <- chat_raw(messages, opts) do
      parse_chat_completion(body)
    end
  end

  @spec chat_raw([chat_message()], keyword()) :: {:ok, response_body()} | {:error, term()}
  def chat_raw(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    payload = chat_payload(messages, opts)

    response =
      Req.post!(
        [
          url: "#{base_url()}/v1/chat/completions",
          json: payload
        ] ++ request_options()
      )

    case response do
      %{status: status, body: body} when status in 200..299 ->
        {:ok, body}

      %{status: status, body: body} ->
        {:error, {:http_error, status, body}}
    end
  rescue
    error -> {:error, error}
  end

  @spec complete(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def complete(prompt) when is_binary(prompt) do
    response =
      Req.post!(
        [
          url: "#{base_url()}/completion",
          json: %{
            prompt: prompt,
            n_predict: 256
          }
        ] ++ request_options()
      )

    case response do
      %{status: status, body: body} when status in 200..299 ->
        {:ok, Map.get(body, "content")}

      %{status: status, body: body} ->
        {:error, {:http_error, status, body}}
    end
  rescue
    error -> {:error, error}
  end

  @spec tool_result_message(tool_call(), map() | String.t()) :: map()
  def tool_result_message(%{id: id, name: name}, result) do
    content =
      if is_binary(result) do
        result
      else
        Jason.encode!(result)
      end

    %{
      role: "tool",
      tool_call_id: id,
      name: name,
      content: content
    }
  end

  defp chat_payload(messages, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @chat_max_tokens)

    %{
      model: Keyword.get(opts, :model, model_name()),
      messages: messages,
      stream: false,
      max_tokens: max_tokens
    }
    |> put_optional_body_opts(opts)
    |> put_tools(opts)
    |> merge_extra_body(opts)
  end

  defp put_optional_body_opts(payload, opts) do
    Enum.reduce(@optional_body_opts, payload, fn key, acc ->
      maybe_put(acc, key, Keyword.get(opts, key))
    end)
  end

  defp put_tools(payload, opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, tools} when is_list(tools) ->
        payload =
          payload
          |> Map.put(:tools, tools)
          |> maybe_put(:tool_choice, normalize_tool_choice(Keyword.get(opts, :tool_choice)))

        if Map.has_key?(payload, :tool_choice) do
          payload
        else
          Map.put(payload, :tool_choice, "auto")
        end

      _other ->
        payload
    end
  end

  defp normalize_tool_choice(nil), do: "auto"

  defp normalize_tool_choice(choice) when choice in ["auto", "none", "required"] do
    choice
  end

  defp normalize_tool_choice(choice) when is_atom(choice) do
    choice
    |> Atom.to_string()
    |> normalize_tool_choice()
  end

  defp normalize_tool_choice(_choice), do: "auto"

  defp merge_extra_body(payload, opts) do
    case Keyword.get(opts, :extra_body, %{}) do
      extra when is_map(extra) -> Map.merge(payload, extra)
      extra when is_list(extra) -> Map.merge(payload, Map.new(extra))
      _other -> payload
    end
  end

  defp maybe_put(payload, _key, nil), do: payload
  defp maybe_put(payload, key, value), do: Map.put(payload, key, value)

  defp parse_chat_completion(body) when is_binary(body) do
    content = String.trim(body)

    if content == "" do
      {:error, :missing_response_content}
    else
      {:ok,
       %{
         content: content,
         finish_reason: nil,
         tool_calls: [],
         message: nil,
         raw: body
       }}
    end
  end

  defp parse_chat_completion(body) when is_map(body) do
    message = assistant_message(body)
    content = chat_content(body)
    finish_reason = finish_reason(body)
    tool_calls = tool_calls(body)

    cond do
      tool_calls != [] ->
        {:ok,
         %{
           content: content,
           finish_reason: finish_reason,
           tool_calls: tool_calls,
           message: message,
           raw: body
         }}

      is_binary(content) and String.trim(content) != "" ->
        {:ok,
         %{
           content: content,
           finish_reason: finish_reason,
           tool_calls: [],
           message: message,
           raw: body
         }}

      true ->
        response_error(body)
    end
  end

  defp parse_chat_completion(_body), do: {:error, :invalid_response_body}

  defp completion_content(%{tool_calls: [_ | _] = tool_calls}, _max_tokens) do
    {:error, {:tool_calls_requested, tool_calls}}
  end

  defp completion_content(%{content: content, finish_reason: "length"}, max_tokens)
       when is_binary(content) do
    {:ok,
     content <>
       "\n\n[Response stopped because it reached the #{max_tokens}-token output limit. Ask a narrower follow-up or request the next part.]"}
  end

  defp completion_content(%{content: content}, _max_tokens) when is_binary(content) do
    case String.trim(content) do
      "" -> {:error, :missing_response_content}
      _content -> {:ok, content}
    end
  end

  defp completion_content(_completion, _max_tokens), do: {:error, :missing_response_content}

  defp assistant_message(body) when is_map(body) do
    get_in(body, ["choices", Access.at(0), "message"])
  end

  defp assistant_message(_body), do: nil

  defp finish_reason(body) when is_map(body) do
    get_in(body, ["choices", Access.at(0), "finish_reason"])
  end

  defp finish_reason(_body), do: nil

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

  defp tool_calls(body) when is_map(body) do
    body
    |> get_in(["choices", Access.at(0), "message", "tool_calls"])
    |> normalize_tool_calls()
  end

  defp tool_calls(_body), do: []

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&normalize_tool_call/1)
    |> Enum.filter(&match?(%{name: name} when is_binary(name), &1))
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp normalize_tool_call(
         %{
           "id" => id,
           "type" => type,
           "function" => %{"name" => name, "arguments" => arguments}
         } = raw
       ) do
    %{
      id: id,
      type: type || "function",
      name: name,
      arguments: normalize_arguments(arguments),
      raw: raw
    }
  end

  defp normalize_tool_call(
         %{
           id: id,
           type: type,
           function: %{name: name, arguments: arguments}
         } = raw
       ) do
    %{
      id: id,
      type: type || "function",
      name: name,
      arguments: normalize_arguments(arguments),
      raw: raw
    }
  end

  defp normalize_tool_call(_tool_call), do: nil

  defp normalize_arguments(arguments) when is_map(arguments), do: arguments

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" ->
        %{}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> decoded
          {:ok, _decoded} -> %{}
          {:error, _reason} -> %{}
        end
    end
  end

  defp normalize_arguments(_arguments), do: %{}

  defp response_error(%{"error" => %{"message" => message}}) when is_binary(message) do
    {:error, {:llm_server_error, message}}
  end

  defp response_error(%{"error" => error}) do
    {:error, {:llm_server_error, error}}
  end

  defp response_error(_body), do: {:error, :missing_response_content}

  defp model_name do
    Application.get_env(:llm, :model_name, "local-model")
  end

  defp base_url do
    Llm.LlamaServer.base_url()
  end

  defp request_options do
    [
      receive_timeout: Application.get_env(:llm, :client_receive_timeout, :infinity),
      connect_options: [
        timeout: Application.get_env(:llm, :client_connect_timeout_ms, 5_000)
      ]
    ]
  end
end
