defmodule PtcManager.Repo.Migrations.AddPrPublications do
  use Ecto.Migration

  def up do
    create table(:pr_publications) do
      add :job_id, references(:jobs, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "queued"
      add :idempotency_key, :string, null: false
      add :fencing_token, :integer, null: false
      add :branch_name, :string, null: false
      add :base_sha, :string, null: false
      add :head_sha, :string, null: false
      add :diff_digest, :string, null: false
      add :attempt_count, :integer, null: false, default: 0
      add :attempt_token, :string
      add :attempt_expires_at, :utc_datetime_usec
      add :next_attempt_at, :utc_datetime_usec
      add :last_error, :string
      add :pr_number, :integer
      add :pr_url, :string
      add :remote_head_sha, :string
      add :published_at, :utc_datetime_usec
      add :pr_state, :string
      add :pr_checked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pr_publications, [:job_id])
    create unique_index(:pr_publications, [:idempotency_key])
    create index(:pr_publications, [:state, :next_attempt_at])
    create index(:pr_publications, [:pr_state, :pr_checked_at])

    execute("""
    INSERT INTO pr_publications (
      job_id, state, idempotency_key, fencing_token, branch_name,
      base_sha, head_sha, diff_digest, attempt_count, next_attempt_at,
      inserted_at, updated_at
    )
    SELECT
      jobs.id, 'queued', printf('%064x', jobs.id), jobs.fencing_token, jobs.branch_name,
      jobs.result_base_sha, jobs.result_head_sha, jobs.result_diff_digest, 0,
      COALESCE(jobs.result_verified_at, jobs.updated_at),
      COALESCE(jobs.result_verified_at, jobs.updated_at), jobs.updated_at
    FROM jobs
    WHERE jobs.state = 'ready_for_pr'
      AND jobs.branch_name IS NOT NULL
      AND jobs.result_base_sha IS NOT NULL
      AND jobs.result_head_sha IS NOT NULL
      AND jobs.result_diff_digest IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM pr_publications WHERE pr_publications.job_id = jobs.id
      )
    """)

    drop_if_exists index(:jobs, [:issue_id], name: :jobs_one_active_per_issue)

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation', 'verifying_result', 'ready_for_pr', 'publishing_pr', 'pr_open', 'publish_blocked')",
             name: :jobs_one_active_per_issue
           )
  end

  def down do
    drop_if_exists index(:jobs, [:issue_id], name: :jobs_one_active_per_issue)

    execute(
      "UPDATE jobs SET state = 'ready_for_pr' WHERE state IN ('publishing_pr', 'pr_open', 'publish_blocked')"
    )

    create unique_index(:jobs, [:issue_id],
             where:
               "state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'reconciling', 'awaiting_reconciliation', 'verifying_result', 'ready_for_pr')",
             name: :jobs_one_active_per_issue
           )

    drop table(:pr_publications)
  end
end
