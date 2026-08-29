defmodule PtcManager.Repo.Migrations.AddJobResults do
  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :result_base_sha, :string
      add :result_head_sha, :string
      add :result_diff_digest, :string
      add :result_commit_count, :integer
      add :result_verified_at, :utc_datetime_usec
    end

    drop unique_index(:jobs, [:issue_id],
           where:
             "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation')",
           name: :jobs_one_active_per_issue
         )

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation', 'ready_for_pr')",
             name: :jobs_one_active_per_issue
           )
  end

  def down do
    drop unique_index(:jobs, [:issue_id],
           where:
             "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation', 'ready_for_pr')",
           name: :jobs_one_active_per_issue
         )

    execute("UPDATE jobs SET state = 'awaiting_reconciliation' WHERE state = 'ready_for_pr'")

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation')",
             name: :jobs_one_active_per_issue
           )

    alter table(:jobs) do
      remove :result_base_sha
      remove :result_head_sha
      remove :result_diff_digest
      remove :result_commit_count
      remove :result_verified_at
    end
  end
end
