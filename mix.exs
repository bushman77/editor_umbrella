defmodule Editor.Umbrella.MixProject do
  use Mix.Project

  @apps_path "apps"
  @version "0.1.0"
  @description "Editor Umbrella Project"

  def project do
    [
      apps_path: @apps_path,
      version: @version,
      description: @description,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # Required for Phoenix live reload and `mix format` for HEEx templates
      listeners: [Phoenix.CodeReloader],
      # Optional: avoid recompilation warnings for umbrella roots
      build_per_environment: false
    ]
  end

  def cli do
    [
      # Ensures `mix precommit` runs in `:test` env by default
      preferred_envs: [precommit: :test]
    ]
  end

  defp deps do
    [
      # Required for `mix format` to handle ~H/HEEx templates at umbrella root
      # only: [:dev, :test], runtime: false}
      {:phoenix_live_view, "~> 1.1.0"}
    ]
  end

  defp aliases do
    [
      # Run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      # Pre-commit checks: compile, unlock unused deps, format, test
      precommit: [
        "compile --warning-as-errors",
        "deps.unlock --unused",
        "format",
        "test"
      ]
    ]
  end
end
