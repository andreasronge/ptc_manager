defmodule PtcManager.Repo.Migrations.AddPrMergeDecisions do
  use Ecto.Migration

  def change do
    alter table(:agent_actions) do
      add :target_snapshot, :map, null: false, default: %{}
    end

    create table(:pr_analyses) do
      add :publication_id, references(:pr_publications, on_delete: :delete_all), null: false
      add :agent_action_id, references(:agent_actions, on_delete: :restrict), null: false
      add :outcome, :string, null: false
      add :plain_summary, :text, null: false
      add :why_it_matters, :text, null: false
      add :scope, :string, null: false
      add :risk, :string, null: false
      add :technical_evidence, :text, null: false
      add :base_repository, :string, null: false
      add :base_ref, :string, null: false
      add :reviewed_base_sha, :string, null: false
      add :head_repository, :string, null: false
      add :head_ref, :string, null: false
      add :head_sha, :string, null: false
      add :diff_digest, :string, null: false
      add :analyzed_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:pr_analyses, [:agent_action_id])
    create index(:pr_analyses, [:publication_id, :analyzed_at])

    create table(:merge_approvals) do
      add :publication_id, references(:pr_publications, on_delete: :restrict), null: false
      add :pr_analysis_id, references(:pr_analyses, on_delete: :restrict), null: false
      add :decision, :string, null: false, default: "approve"
      add :actor, :string, null: false
      add :base_repository, :string, null: false
      add :base_ref, :string, null: false
      add :reviewed_base_sha, :string, null: false
      add :head_sha, :string, null: false
      add :diff_digest, :string, null: false
      add :approved_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:merge_approvals, [:pr_analysis_id])
    create index(:merge_approvals, [:publication_id, :approved_at])
  end
end
