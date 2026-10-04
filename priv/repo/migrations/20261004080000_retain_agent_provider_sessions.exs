defmodule PtcManager.Repo.Migrations.RetainAgentProviderSessions do
  use Ecto.Migration

  def up do
    alter table(:agent_runs) do
      add :provider_sessions, :map, default: %{}, null: false
    end

    flush()

    execute("""
    WITH RECURSIVE sessions(id, session) AS (
      SELECT id, external_key FROM agent_runs WHERE external_key IS NOT NULL
      UNION ALL
      SELECT id, substr(session, instr(session, ':') + 1)
      FROM sessions WHERE instr(session, ':') > 0
    )
    UPDATE agent_runs SET provider_sessions = json_object(
      (SELECT session FROM sessions WHERE sessions.id = agent_runs.id AND instr(session, ':') = 0),
      COALESCE(
        (SELECT w.agent_kind FROM worktree_allocations w WHERE w.job_id = agent_runs.job_id LIMIT 1),
        (SELECT i.selected_agent_kind FROM automation_invocations i
          WHERE i.agent_action_id = agent_runs.agent_action_id ORDER BY i.id DESC LIMIT 1),
        'unknown')
    ) WHERE external_key IS NOT NULL
    """)
  end

  def down do
    alter table(:agent_runs) do
      remove :provider_sessions
    end
  end
end
