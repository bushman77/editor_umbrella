defmodule Llm do
  @moduledoc """
  Public API for interacting with the local llama-server instance.
  """

  alias Llm.Client
  alias Llm.LlamaServer

  @type context :: Llm.Rag.context()

  def chat(message, opts \\ [])

  def chat(message, opts) when is_binary(message) and is_list(opts) do
    chat([%{role: "user", content: message}], opts)
  end

  def chat(messages, opts) when is_list(messages) and is_list(opts) do
    if enabled?() do
      with :ok <- LlamaServer.ensure_running() do
        Client.chat(messages, opts)
      end
    else
      {:error, :llm_disabled}
    end
  end

  def build_context(root_path, selected_file, question, opts \\ [])
      when is_binary(root_path) and is_binary(question) do
    Llm.Rag.build_context(root_path, selected_file, question, opts)
  end

  def status do
    if enabled?() do
      LlamaServer.status()
    else
      %{enabled?: false, ready?: false, reason: :llm_disabled}
    end
  end

  def ready? do
    enabled?() and LlamaServer.ready?()
  end

  def enabled? do
    Application.get_env(:llm, :enabled, true)
  end
end
