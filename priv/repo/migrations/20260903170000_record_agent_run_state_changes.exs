defmodule PtcManager.Repo.Migrations.RecordAgentRunStateChanges do
  use Ecto.Migration

  # A Herdr snapshot refreshes an agent run every few seconds, so both
  # `last_heartbeat_at` and `updated_at` stay current while an agent sits at a
  # prompt nobody answers. Only the moment its state last changed separates a
  # normal pause mid-turn from a session that has been waiting for a person for
  # a day. Existing rows adopt their last update, which is the earliest instant
  # the observed state is known to have held.
  def up do
    alter table(:agent_runs) do
      add :state_changed_at, :utc_datetime_usec
    end

    execute "UPDATE agent_runs SET state_changed_at = updated_at"

    create index(:agent_runs, [:state, :state_changed_at])
  end

  def down do
    drop index(:agent_runs, [:state, :state_changed_at])

    alter table(:agent_runs) do
      remove :state_changed_at
    end
  end
end
