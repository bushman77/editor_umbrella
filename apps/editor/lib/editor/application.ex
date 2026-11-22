defmodule Editor.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Editor.Repo,
      {DNSCluster, query: Application.get_env(:editor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Editor.PubSub},
      Editor.OpenFileCache
      # Start a worker by calling: Editor.Worker.start_link(arg)
      # {Editor.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Editor.Supervisor)
  end
end
