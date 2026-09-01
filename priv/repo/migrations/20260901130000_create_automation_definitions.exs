defmodule PtcManager.Repo.Migrations.CreateAutomationDefinitions do
  use Ecto.Migration

  def change do
    create table(:automation_definitions) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :name, :string, null: false
      add :description, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:automation_definitions, [:repository_id, :key])
    create index(:automation_definitions, [:repository_id, :enabled])

    create table(:automation_definition_versions) do
      add :automation_definition_id,
          references(:automation_definitions, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :target_type, :string, null: false
      add :execution_profile, :string, null: false
      add :agent_selector, :map, null: false, default: %{}
      add :github_access, :string, null: false
      add :queue_lane, :string, null: false
      add :resource_class, :string, null: false
      add :lock_policy, :map, null: false, default: %{}
      add :timeout_seconds, :integer, null: false
      add :result_type, :string, null: false
      add :result_protocol_version, :integer, null: false, default: 1
      add :operational_policy, :text, null: false, default: ""
      add :prompt, :text, null: false, default: ""
      add :configuration_snapshot, :map, null: false, default: %{}
      add :created_by, :string, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:automation_definition_versions, [
             :automation_definition_id,
             :version
           ])

    create index(:automation_definition_versions, [:execution_profile, :queue_lane])

    alter table(:automation_definitions) do
      add :current_version_id,
          references(:automation_definition_versions, on_delete: :restrict)
    end

    alter table(:agent_actions) do
      add :automation_definition_version_id,
          references(:automation_definition_versions, on_delete: :restrict)
    end

    create index(:agent_actions, [:automation_definition_version_id])

    alter table(:jobs) do
      add :automation_definition_version_id,
          references(:automation_definition_versions, on_delete: :restrict)

      add :prompt_instructions, :text
    end

    create index(:jobs, [:automation_definition_version_id])
  end
end
