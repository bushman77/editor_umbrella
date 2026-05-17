defmodule Llm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Llm.Supervisor]
    Supervisor.start_link(child_specs(), opts)
  end

  @spec child_specs() :: [Supervisor.child_spec()]
  def child_specs do
    [
      {Llm.Conversation, []},
      {Llm.Codex, []}
    ] ++ opencode_acp_child_specs() ++ llama_server_child_specs()
  end

  defp opencode_acp_child_specs do
    if Application.get_env(:llm, :opencode_acp_enabled, true) do
      [{Llm.OpenCodeACP, []}]
    else
      []
    end
  end

  defp llama_server_child_specs do
    if Application.get_env(:llm, :enabled, true) do
      [{Llm.LlamaServer, []}]
    else
      []
    end
  end
end
