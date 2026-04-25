defmodule Llm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Llm.LlamaServer, []}
    ]

    opts = [strategy: :one_for_one, name: Llm.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
