defmodule PtcManager.Repo.Migrations.SerializeAgentActionsPerTarget do
  use Ecto.Migration

  def up do
    ensure_no_ambiguous_external_actions!()

    drop unique_index(:agent_actions, [:action_key, :target_type, :target_id],
           name: :agent_actions_one_active_per_target
         )

    execute("""
    WITH ranked AS (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY target_type, target_id
          ORDER BY
            CASE state
              WHEN 'sync_pending' THEN 0
              WHEN 'running' THEN 1
              ELSE 2
            END,
            requested_at,
            id
        ) AS position
      FROM agent_actions
      WHERE state IN ('queued', 'running', 'sync_pending')
    )
    UPDATE agent_actions
    SET
      state = 'failed',
      ended_at = COALESCE(ended_at, CURRENT_TIMESTAMP),
      attempt_expires_at = NULL,
      next_sync_attempt_at = NULL,
      last_error = 'Stopped while queued during upgrade: another maintainer action already owns this GitHub target.'
    WHERE
      state = 'queued' AND
      id IN (SELECT id FROM ranked WHERE position > 1)
    """)

    execute("""
    UPDATE agent_runs
    SET
      state = 'lost',
      status_text = 'Stopped during upgrade because another maintainer action owns this GitHub target.',
      ended_at = COALESCE(ended_at, CURRENT_TIMESTAMP),
      last_heartbeat_at = CURRENT_TIMESTAMP
    WHERE
      state IN ('queued', 'starting', 'working', 'idle', 'blocked', 'unknown') AND
      agent_action_id IN (
        SELECT id
        FROM agent_actions
        WHERE
          state = 'failed' AND
          last_error = 'Stopped while queued during upgrade: another maintainer action already owns this GitHub target.'
      )
    """)

    create unique_index(:agent_actions, [:target_type, :target_id],
             where: "state IN ('queued', 'running', 'sync_pending')",
             name: :agent_actions_one_active_per_target
           )
  end

  def down do
    drop unique_index(:agent_actions, [:target_type, :target_id],
           name: :agent_actions_one_active_per_target
         )

    create unique_index(:agent_actions, [:action_key, :target_type, :target_id],
             where: "state IN ('queued', 'running', 'sync_pending')",
             name: :agent_actions_one_active_per_target
           )
  end

  defp ensure_no_ambiguous_external_actions! do
    result =
      repo().query!("""
      SELECT target_type, target_id, COUNT(*)
      FROM agent_actions
      WHERE state IN ('running', 'sync_pending')
      GROUP BY target_type, target_id
      HAVING COUNT(*) > 1
      """)

    if result.rows != [] do
      conflicts =
        Enum.map_join(result.rows, ", ", fn [target_type, target_id, count] ->
          "#{target_type}:#{target_id} (#{count} actions)"
        end)

      raise """
      cannot serialize maintainer actions while multiple running or sync-pending actions own the same target: #{conflicts}.
      Stop the maintainer-action worker, reconcile those GitHub outcomes, and leave at most one running or sync-pending action per target before retrying the migration.
      """
    end
  end
end
