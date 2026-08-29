defmodule PtcManager.Repo.Migrations.AddAgentActionSyncBackoff do
  use Ecto.Migration

  def change do
    alter table(:agent_actions) do
      add :sync_attempt_count, :integer, null: false, default: 0
      add :next_sync_attempt_at, :utc_datetime_usec
    end

    create index(:agent_actions, [:state, :next_sync_attempt_at])
  end
end
