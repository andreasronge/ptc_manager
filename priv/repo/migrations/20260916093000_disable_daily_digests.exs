defmodule PtcManager.Repo.Migrations.DisableDailyDigests do
  use Ecto.Migration

  @reason "Daily updates are disabled pending redesign."

  def up do
    execute """
    UPDATE automation_triggers
    SET enabled = 0, next_run_at = NULL, updated_at = CURRENT_TIMESTAMP
    WHERE automation_definition_id IN (
      SELECT id FROM automation_definitions WHERE key = 'daily_digest'
    )
    """

    execute """
    UPDATE automation_definitions
    SET enabled = 0, updated_at = CURRENT_TIMESTAMP
    WHERE key = 'daily_digest'
    """

    execute """
    UPDATE automation_invocations
    SET state = 'cancelled', ended_at = CURRENT_TIMESTAMP,
        last_error = '#{@reason}', updated_at = CURRENT_TIMESTAMP
    WHERE agent_action_id IN (
      SELECT id FROM agent_actions
      WHERE action_key = 'daily_digest' AND state = 'queued'
    )
      AND state = 'queued'
    """

    execute """
    UPDATE agent_actions
    SET state = 'cancelled', ended_at = CURRENT_TIMESTAMP,
        attempt_token = NULL, attempt_expires_at = NULL,
        next_sync_attempt_at = NULL, last_error = '#{@reason}',
        updated_at = CURRENT_TIMESTAMP
    WHERE action_key = 'daily_digest' AND state = 'queued'
    """
  end

  def down do
    execute """
    UPDATE automation_definitions
    SET enabled = 1, updated_at = CURRENT_TIMESTAMP
    WHERE key = 'daily_digest'
    """
  end
end
