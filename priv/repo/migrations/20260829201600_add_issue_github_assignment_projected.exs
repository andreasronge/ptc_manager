defmodule PtcManager.Repo.Migrations.AddIssueGithubAssignmentProjected do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_assignment_projected, :boolean, null: false, default: false
    end
  end
end
