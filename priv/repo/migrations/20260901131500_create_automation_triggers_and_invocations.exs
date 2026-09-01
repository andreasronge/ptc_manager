defmodule PtcManager.Repo.Migrations.CreateAutomationTriggersAndInvocations do
  use Ecto.Migration

  def change do
    create table(:automation_triggers) do
      add :automation_definition_id,
          references(:automation_definitions, on_delete: :delete_all),
          null: false

      add :trigger_type, :string, null: false
      add :surface, :string, null: false
      add :label, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :configuration, :map, null: false, default: %{}
      add :cron_expression, :string
      add :time_zone, :string
      add :next_run_at, :utc_datetime_usec
      add :last_enqueued_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:automation_triggers, [
             :automation_definition_id,
             :trigger_type,
             :surface
           ])

    create index(:automation_triggers, [:trigger_type, :enabled, :next_run_at])

    create table(:automation_invocations) do
      add :repository_id, references(:repositories, on_delete: :restrict), null: false

      add :automation_definition_version_id,
          references(:automation_definition_versions, on_delete: :restrict),
          null: false

      add :automation_trigger_id, references(:automation_triggers, on_delete: :nilify_all)
      add :agent_action_id, references(:agent_actions, on_delete: :nilify_all)
      add :job_id, references(:jobs, on_delete: :nilify_all)
      add :trigger_type, :string, null: false
      add :trigger_context, :map, null: false, default: %{}
      add :occurrence_key, :string
      add :state, :string, null: false, default: "queued"
      add :source_sha, :string
      add :selected_agent_kind, :string
      add :selected_agent_name, :string
      add :result_status, :string
      add :result_markdown, :text
      add :requested_by, :string, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:automation_invocations, [:repository_id, :state, :requested_at])
    create index(:automation_invocations, [:automation_definition_version_id, :requested_at])
    create index(:automation_invocations, [:agent_action_id])
    create index(:automation_invocations, [:job_id])

    create unique_index(:automation_invocations, [:automation_trigger_id, :occurrence_key],
             where: "automation_trigger_id IS NOT NULL AND occurrence_key IS NOT NULL"
           )
  end
end
