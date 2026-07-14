# apps/editor/priv/repo/migrations/20260710120000_create_workspaces_projects.exs
defmodule Editor.Repo.Migrations.CreateWorkspacesProjects do
  use Ecto.Migration

  def change do
    create table(:workspaces_projects) do
      add :name, :string, null: false
      add :type, :string, null: false, default: "git"
      add :git_url, :string, null: false
      add :branch, :string, null: false, default: "main"
      add :local_path, :string, null: false
      add :last_synced_at, :utc_datetime_usec
      add :last_sync_status, :string
      add :last_sync_error, :text

      timestamps()
    end

    create unique_index(:workspaces_projects, [:name])
    create unique_index(:workspaces_projects, [:local_path])
  end
end
