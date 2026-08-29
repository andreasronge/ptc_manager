defmodule PtcManager.Repo.Migrations.KeepVerifyingResultActive do
  use Ecto.Migration

  def up do
    drop unique_index(:jobs, [:issue_id], name: :jobs_one_active_per_issue)

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation', 'verifying_result', 'ready_for_pr')",
             name: :jobs_one_active_per_issue
           )
  end

  def down do
    drop unique_index(:jobs, [:issue_id], name: :jobs_one_active_per_issue)

    execute("UPDATE jobs SET state = 'awaiting_reconciliation' WHERE state = 'verifying_result'")

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation', 'ready_for_pr')",
             name: :jobs_one_active_per_issue
           )
  end
end
