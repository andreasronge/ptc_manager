defmodule PtcManager.Repo.Migrations.AddAgentPrWorktrees do
  use Ecto.Migration

  def up do
    alter table(:repositories) do
      add :required_pre_pr_reviews, :integer, null: false, default: 2
      add :implementation_test_command, :text
    end

    alter table(:pr_publications) do
      add :source, :string, null: false, default: "broker"
    end

    create table(:worktree_allocations) do
      add :worker_id, references(:workers, on_delete: :restrict), null: false
      add :job_id, references(:jobs, on_delete: :delete_all), null: false
      add :state, :string, null: false, default: "reserved"
      add :path, :text
      add :herdr_workspace, :string
      add :agent_kind, :string
      add :head_sha, :string
      add :pr_number, :integer
      add :pr_url, :string
      add :last_used_at, :utc_datetime_usec, null: false
      add :removed_at, :utc_datetime_usec
      add :cleanup_token, :string
      add :cleanup_expires_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:worktree_allocations, [:job_id])
    create index(:worktree_allocations, [:worker_id, :state, :last_used_at])

    execute("""
    INSERT INTO workers (
      worker_key, name, status, capabilities, inserted_at, updated_at
    )
    SELECT
      jobs.lease_owner,
      'Recovered ' || jobs.lease_owner,
      'offline',
      '{"ptc_manager_recovered_placeholder":true}',
      MIN(jobs.updated_at),
      MAX(jobs.updated_at)
    FROM jobs
    WHERE jobs.lease_owner IS NOT NULL
      AND jobs.state IN (
        'starting', 'working', 'idle', 'blocked', 'reconciling',
        'awaiting_reconciliation', 'verifying_result', 'ready_for_pr',
        'publishing_pr', 'pr_open', 'publish_blocked'
      )
      AND NOT EXISTS (
        SELECT 1 FROM workers WHERE workers.worker_key = jobs.lease_owner
      )
    GROUP BY jobs.lease_owner
    """)

    execute("""
    INSERT INTO worktree_allocations (
      worker_id, job_id, state, herdr_workspace, last_used_at,
      last_error, inserted_at, updated_at
    )
    SELECT
      workers.id,
      jobs.id,
      'attention',
      (
        SELECT agent_runs.herdr_workspace
        FROM agent_runs
        WHERE agent_runs.job_id = jobs.id
        ORDER BY agent_runs.inserted_at DESC, agent_runs.id DESC
        LIMIT 1
      ),
      COALESCE(jobs.started_at, jobs.updated_at),
      'Migrated active worktree: verify its local path before cleanup.',
      COALESCE(jobs.started_at, jobs.updated_at),
      jobs.updated_at
    FROM jobs
    JOIN workers ON workers.worker_key = jobs.lease_owner
    WHERE jobs.state IN (
      'starting', 'working', 'idle', 'blocked', 'reconciling',
      'awaiting_reconciliation', 'verifying_result', 'ready_for_pr',
      'publishing_pr', 'pr_open', 'publish_blocked'
    )
      AND NOT EXISTS (
        SELECT 1 FROM worktree_allocations
        WHERE worktree_allocations.job_id = jobs.id
      )
    """)
  end

  def down do
    drop table(:worktree_allocations)

    execute("""
    DELETE FROM workers
    WHERE json_extract(capabilities, '$.ptc_manager_recovered_placeholder') = 1
      AND NOT EXISTS (
        SELECT 1 FROM agent_runs WHERE agent_runs.worker_id = workers.id
      )
    """)

    alter table(:pr_publications) do
      remove :source
    end

    alter table(:repositories) do
      remove :implementation_test_command
      remove :required_pre_pr_reviews
    end
  end
end
