defmodule PtcManager.Repo.Migrations.AddJobLeases do
  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :branch_name, :string
      add :last_error, :text
      add :reconciling_at, :utc_datetime_usec
      add :absence_observed_at, :utc_datetime_usec
    end

    alter table(:agent_runs) do
      add :fencing_token, :integer, null: false, default: 0
    end

    create index(:jobs, [:state, :inserted_at])
    create index(:jobs, [:lease_expires_at])

    drop unique_index(:jobs, [:issue_id],
           where: "state IN ('queued', 'starting', 'working', 'idle', 'blocked')",
           name: :jobs_one_active_per_issue
         )

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation')",
             name: :jobs_one_active_per_issue
           )

    create unique_index(:agent_runs, [:job_id, :fencing_token],
             where: "job_id IS NOT NULL",
             name: :agent_runs_one_per_job_attempt
           )
  end

  def down do
    drop unique_index(:agent_runs, [:job_id, :fencing_token],
           where: "job_id IS NOT NULL",
           name: :agent_runs_one_per_job_attempt
         )

    drop unique_index(:jobs, [:issue_id],
           where:
             "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation')",
           name: :jobs_one_active_per_issue
         )

    create unique_index(:jobs, [:issue_id],
             where: "state IN ('queued', 'starting', 'working', 'idle', 'blocked')",
             name: :jobs_one_active_per_issue
           )

    drop index(:jobs, [:lease_expires_at])
    drop index(:jobs, [:state, :inserted_at])

    alter table(:agent_runs) do
      remove :fencing_token
    end

    alter table(:jobs) do
      remove :lease_owner
      remove :lease_expires_at
      remove :started_at
      remove :ended_at
      remove :branch_name
      remove :last_error
      remove :reconciling_at
      remove :absence_observed_at
    end
  end
end
