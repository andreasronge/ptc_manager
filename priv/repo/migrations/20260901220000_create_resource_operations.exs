defmodule PtcManager.Repo.Migrations.CreateResourceOperations do
  use Ecto.Migration

  def change do
    alter table(:capacity_settings) do
      add :operation_capacity, :integer, null: false, default: 1
    end

    create table(:capacity_changes) do
      add :worker_id, references(:workers, on_delete: :nilify_all)
      add :worker_incarnation_id, :string
      add :light_agent_capacity, :integer, null: false
      add :heavy_agent_capacity, :integer, null: false
      add :operation_capacity, :integer, null: false
      add :effective_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:capacity_changes, [:worker_id, :effective_at])

    create table(:resource_operations) do
      add :worker_id, references(:workers, on_delete: :restrict), null: false
      add :repository_id, references(:repositories, on_delete: :restrict), null: false
      add :job_id, references(:jobs, on_delete: :restrict)
      add :agent_action_id, references(:agent_actions, on_delete: :restrict)
      add :agent_run_id, references(:agent_runs, on_delete: :restrict), null: false
      add :invocation_id, :string, null: false
      add :label, :string, null: false
      add :priority, :integer, null: false, default: 0
      add :state, :string, null: false, default: "queued"
      add :slot_number, :integer
      add :fencing_token, :integer, null: false, default: 0
      add :attempt_token, :string
      add :wrapper_pid, :integer
      add :cgroup_path, :string
      add :queued_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :wait_duration_ms, :integer
      add :run_duration_ms, :integer
      add :exit_status, :integer
      add :peak_memory_bytes, :integer
      add :cancellation_reason, :string
      add :last_error, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:resource_operations, [:invocation_id])
    create index(:resource_operations, [:worker_id, :state, :priority, :queued_at])
    create index(:resource_operations, [:repository_id, :finished_at])
    create index(:resource_operations, [:agent_run_id, :state])

    create unique_index(:resource_operations, [:worker_id, :slot_number],
             where:
               "slot_number IS NOT NULL AND state IN " <>
                 "('starting', 'running', 'cancelling', 'recovery_pending')",
             name: :resource_operations_one_active_owner_per_slot
           )

    execute(
      """
      CREATE TRIGGER resource_operations_exactly_one_owner_insert
      BEFORE INSERT ON resource_operations
      WHEN NOT (
        (NEW.job_id IS NOT NULL AND NEW.agent_action_id IS NULL) OR
        (NEW.job_id IS NULL AND NEW.agent_action_id IS NOT NULL)
      )
      BEGIN
        SELECT RAISE(ABORT, 'resource operation must have exactly one owner');
      END
      """,
      "DROP TRIGGER IF EXISTS resource_operations_exactly_one_owner_insert"
    )

    execute(
      """
      CREATE TRIGGER resource_operations_exactly_one_owner_update
      BEFORE UPDATE OF job_id, agent_action_id ON resource_operations
      WHEN NOT (
        (NEW.job_id IS NOT NULL AND NEW.agent_action_id IS NULL) OR
        (NEW.job_id IS NULL AND NEW.agent_action_id IS NOT NULL)
      )
      BEGIN
        SELECT RAISE(ABORT, 'resource operation must have exactly one owner');
      END
      """,
      "DROP TRIGGER IF EXISTS resource_operations_exactly_one_owner_update"
    )

    execute(
      """
      INSERT INTO capacity_changes (
        light_agent_capacity,
        heavy_agent_capacity,
        operation_capacity,
        effective_at,
        inserted_at
      )
      SELECT
        light_agent_capacity,
        heavy_agent_capacity,
        operation_capacity,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      FROM capacity_settings
      """,
      "DELETE FROM capacity_changes WHERE worker_id IS NULL"
    )
  end
end
