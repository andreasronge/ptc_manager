defmodule PtcManager.Repo.Migrations.CreateCollectionRuns do
  use Ecto.Migration

  @moduledoc """
  A collection run is the maintainer's one decision that a collection may be
  delivered unattended. Members freeze the authorized membership; steps record
  every automatic effect once, so a bound is a row and a race is a no-op.
  """

  def change do
    create table(:collection_runs) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "active"
      add :auto_merge, :boolean, null: false, default: true
      add :auto_recover, :boolean, null: false, default: true
      add :pause_sequence, :integer, null: false, default: 0
      add :pause_kind, :string
      add :pause_reason, :string
      add :pause_scope, :string
      add :paused_issue_number, :integer
      add :pause_reference_id, :integer
      add :paused_at, :utc_datetime_usec
      add :escalation_pending, :boolean, null: false, default: false
      add :end_reason, :string
      add :actor, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:collection_runs, [:repository_id, :state])

    create unique_index(:collection_runs, [:issue_id],
             where: "state IN ('active', 'paused', 'finishing')",
             name: :collection_runs_one_live_per_issue
           )

    create table(:collection_run_members) do
      add :run_id, references(:collection_runs, on_delete: :delete_all), null: false
      add :issue_number, :integer, null: false
      add :issue_id, references(:issues, on_delete: :nilify_all)
      add :added_by, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:collection_run_members, [:run_id, :issue_number])

    create table(:collection_run_steps) do
      add :run_id, references(:collection_runs, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :scope, :string, null: false
      add :agent_action_id, references(:agent_actions, on_delete: :nilify_all)
      add :job_id, references(:jobs, on_delete: :nilify_all)
      add :actor, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:collection_run_steps, [:run_id, :kind, :scope])
    create index(:collection_run_steps, [:agent_action_id])
  end
end
