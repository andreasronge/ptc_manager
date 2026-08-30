defmodule PtcManager.Repo.Migrations.AddLinkedIssueNumbersToPrPublications do
  use Ecto.Migration

  def change do
    alter table(:pr_publications) do
      add :linked_issue_numbers, :map, null: false, default: %{"numbers" => []}
    end
  end
end
