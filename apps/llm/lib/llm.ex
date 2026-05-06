defmodule Llm do
  @moduledoc """
  Public API for interacting with the local llama-server instance.
  """

  alias Llm.Client
  alias Llm.LlamaServer

  @type context :: Llm.Rag.context()
  @type chat_message :: %{required(:role) => String.t(), required(:content) => String.t()}
  @type chat_result :: {:ok, String.t()} | {:error, term()}
  @type status :: %{
          required(:enabled?) => boolean(),
          optional(:running?) => boolean(),
          optional(:ready?) => boolean(),
          optional(:started_by_app?) => boolean(),
          optional(:last_exit_status) => non_neg_integer() | nil,
          optional(:reason) => atom()
        }

  @spec chat(String.t() | [chat_message()], keyword()) :: chat_result()
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

  @spec build_context(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, context()} | {:error, term()}
  def build_context(root_path, selected_file, question, opts \\ [])
      when is_binary(root_path) and is_binary(question) do
    Llm.Rag.build_context(root_path, selected_file, question, opts)
  end

  @spec status() :: status()
  def status do
    if enabled?() do
      LlamaServer.status()
      |> Map.put(:enabled?, true)
    else
      %{enabled?: false, ready?: false, reason: :llm_disabled}
    end
  end

  @spec ready?() :: boolean()
  def ready? do
    enabled?() and LlamaServer.ready?()
  end

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:llm, :enabled, true)
  end
end
