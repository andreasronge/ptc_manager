defmodule PtcManager.Repo.Migrations.AddPrePublicationGateEvidence do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :pre_publication_bootstrap_command, :text
      add :pre_publication_bootstrap_timeout_ms, :integer
      add :pre_publication_command, :text
      add :pre_publication_timeout_ms, :integer
      add :pre_publication_config_digest, :string
      add :pre_publication_status, :string
      add :pre_publication_verified_sha, :string
      add :pre_publication_exit_status, :integer
      add :pre_publication_output, :text
      add :pre_publication_duration_ms, :integer
      add :pre_publication_verified_at, :utc_datetime_usec
    end

    execute(
      """
      UPDATE jobs
      SET state = 'awaiting_reconciliation',
          result_attempt_token = NULL,
          result_attempt_expires_at = NULL,
          last_error = 'Exact-SHA repository contract verification required after upgrade'
      WHERE id IN (
        SELECT job_id
        FROM pr_publications
        WHERE source = 'broker'
          AND pr_number IS NULL
          AND state IN ('queued', 'publishing', 'blocked')
      )
      """,
      "SELECT 1"
    )
  end
end
