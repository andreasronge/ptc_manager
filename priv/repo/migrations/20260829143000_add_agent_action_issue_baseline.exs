defmodule PtcManager.Repo.Migrations.AddAgentActionIssueBaseline do
  use Ecto.Migration

  def change do
    alter table(:agent_actions) do
      add :baseline_issue_numbers, :map, null: false, default: %{"numbers" => []}
    end
  end
end
