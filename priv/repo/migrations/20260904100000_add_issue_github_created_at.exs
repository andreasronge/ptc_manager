defmodule PtcManager.Repo.Migrations.AddIssueGithubCreatedAt do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_created_at, :utc_datetime_usec
    end
  end
end
