defmodule PtcManager.Repo.Migrations.CompleteTerminalHeadAdvancedPublications do
  use Ecto.Migration

  @terminal_head_mismatch """
  publication.state = 'blocked'
  AND publication.pr_state IN ('merged', 'closed')
  AND publication.head_ref = publication.branch_name
  AND publication.last_error IN (
    'GitHub reports a different agent branch or head commit.',
    'GitHub reports a different agent branch head commit.',
    'GitHub reports a different pull-request head commit.'
  )
  AND EXISTS (
    SELECT 1
    FROM repositories AS repository
    WHERE repository.id = publication.repository_id
      AND lower(publication.head_repository) =
          lower(repository.github_owner || '/' || repository.github_name)
  )
  """

  def up do
    execute("""
    INSERT INTO audit_events (
      actor,
      action,
      target_type,
      target_id,
      details,
      inserted_at
    )
    SELECT
      'migration',
      'pr_publication.terminal_head_advanced_recovered',
      'pr_publication',
      publication.id,
      '{"reason":"GitHub confirmed the expected branch was terminal after its head advanced."}',
      strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    FROM pr_publications AS publication
    WHERE #{@terminal_head_mismatch}
    """)

    execute("""
    UPDATE jobs
    SET state = CASE
          WHEN publication.pr_state = 'merged' THEN 'done'
          ELSE 'cancelled'
        END,
        ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        last_error = NULL,
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    FROM pr_publications AS publication
    WHERE jobs.id = publication.job_id
      AND jobs.state = 'publish_blocked'
      AND #{@terminal_head_mismatch}
    """)

    execute("""
    UPDATE worktree_allocations
    SET state = 'terminal',
        last_error = NULL,
        last_used_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE job_id IN (
      SELECT publication.job_id
      FROM pr_publications AS publication
      WHERE #{@terminal_head_mismatch}
    )
      AND state NOT IN ('cleaning', 'removed')
    """)

    execute("""
    UPDATE agent_runs
    SET state = 'done',
        status_text = CASE
          WHEN (
            SELECT publication.pr_state
            FROM pr_publications AS publication
            WHERE publication.job_id = agent_runs.job_id
          ) = 'merged'
            THEN 'PR merged; the retained session is ready for cleanup.'
          ELSE 'PR closed; the retained session is ready for cleanup.'
        END,
        ended_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        last_heartbeat_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE job_id IN (
      SELECT publication.job_id
      FROM pr_publications AS publication
      WHERE #{@terminal_head_mismatch}
    )
      AND state NOT IN ('failed', 'lost')
    """)

    execute("""
    UPDATE pr_publications AS publication
    SET state = 'published',
        last_error = NULL,
        next_attempt_at = NULL,
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE #{@terminal_head_mismatch}
    """)
  end

  def down, do: :ok
end
