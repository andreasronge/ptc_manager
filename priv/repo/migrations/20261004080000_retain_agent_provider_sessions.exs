defmodule PtcManager.Repo.Migrations.RetainAgentProviderSessions do
  use Ecto.Migration

  def up do
    alter table(:agent_runs) do
      add :provider_sessions, :map, default: %{}, null: false
    end

    flush()

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(repo(), """
      SELECT r.id, r.external_key,
        COALESCE(
          (SELECT w.agent_kind FROM worktree_allocations w WHERE w.job_id = r.job_id LIMIT 1),
          (SELECT i.selected_agent_kind FROM automation_invocations i
            WHERE i.agent_action_id = r.agent_action_id ORDER BY i.id DESC LIMIT 1),
          'unknown')
      FROM agent_runs r WHERE r.external_key IS NOT NULL
      """)

    Enum.each(rows, fn [id, key, kind] ->
      session = key |> String.split(":") |> List.last()

      Ecto.Adapters.SQL.query!(
        repo(),
        "UPDATE agent_runs SET provider_sessions = ? WHERE id = ?",
        [Jason.encode!(%{session => kind}), id]
      )
    end)
  end

  def down do
    alter table(:agent_runs) do
      remove :provider_sessions
    end
  end
end
