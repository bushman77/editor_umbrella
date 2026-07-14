# apps/editor/lib/editor/workspaces/project.ex
defmodule Editor.Workspaces.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @types [:git]

  schema "workspaces_projects" do
    field :name, :string
    field :type, Ecto.Enum, values: @types, default: :git
    field :git_url, :string
    field :branch, :string, default: "main"
    field :local_path, :string
    field :last_synced_at, :utc_datetime_usec
    field :last_sync_status, :string
    field :last_sync_error, :string

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :type, :git_url, :branch, :local_path])
    |> validate_required([:name, :type, :git_url, :branch])
    |> validate_git_url()
    |> put_default_local_path()
  end

  defp validate_git_url(changeset) do
    validate_change(changeset, :git_url, fn :git_url, url ->
      if String.starts_with?(url, ["git@", "https://", "http://"]) do
        []
      else
        [git_url: "must start with git@, https://, or http://"]
      end
    end)
  end

  defp put_default_local_path(changeset) do
    case get_field(changeset, :local_path) do
      nil ->
        name = get_field(changeset, :name) || "workspace"
        slug = slugify(name)
        put_change(changeset, :local_path, Path.join(base_path(), slug))
      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp base_path do
    home = System.get_env("HOME") || System.tmp_dir!()
    Path.join([home, ".editor_umbrella", "workspaces"])
  end
  # apps/editor/lib/editor/workspaces/project.ex — add this function

  def sync_changeset(project, attrs) do
    project
    |> cast(attrs, [:last_synced_at, :last_sync_status, :last_sync_error])
  end
end
