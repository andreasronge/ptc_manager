defmodule PtcManager.Repo.Migrations.AddIssueGithubAssignees do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_assignees, :map, null: false, default: %{"logins" => []}
    end
  end
end
