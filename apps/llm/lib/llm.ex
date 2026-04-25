defmodule Llm do
  @moduledoc """
  Public API for interacting with the local llama-server instance.
  """

  alias Llm.Client
  alias Llm.LlamaServer

  def chat(message) when is_binary(message) do
    chat([%{role: "user", content: message}])
  end

  def chat(messages) when is_list(messages) do
    with :ok <- LlamaServer.ensure_running() do
      Client.chat(messages)
    end
  end

  def status do
    LlamaServer.status()
  end

  def ready? do
    LlamaServer.ready?()
  end
end
