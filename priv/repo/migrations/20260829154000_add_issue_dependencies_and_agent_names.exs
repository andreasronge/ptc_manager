defmodule PtcManager.Repo.Migrations.AddIssueDependenciesAndAgentNames do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :agent_name, :string
    end

    create table(:issue_dependencies) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :blocking_issue_id, references(:issues, on_delete: :nilify_all)
      add :blocking_issue_number, :integer, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:issue_dependencies, [:issue_id, :blocking_issue_number])
    create index(:issue_dependencies, [:blocking_issue_id])
  end
end
