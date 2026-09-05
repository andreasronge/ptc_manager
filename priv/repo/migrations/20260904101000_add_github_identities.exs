defmodule PtcManager.Repo.Migrations.AddGithubIdentities do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_author_login, :string
    end

    alter table(:repositories) do
      add :github_viewer_login, :string
    end
  end
end
