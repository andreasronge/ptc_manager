defmodule PtcManager.Repo.Migrations.AddGenericAgentActions do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :workflow_label, :string
    end

    create table(:agent_actions) do
      add :repository_id, references(:repositories, on_delete: :restrict), null: false
      add :action_key, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :integer, null: false
      add :target_label, :string, null: false
      add :prompt_version, :integer, null: false, default: 1
      add :prompt, :text, null: false
      add :actor, :string, null: false
      add :state, :string, null: false, default: "queued"
      add :attempt_count, :integer, null: false, default: 0
      add :attempt_token, :string
      add :attempt_expires_at, :utc_datetime_usec
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :result_summary, :text
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_actions, [:state, :requested_at])
    create index(:agent_actions, [:target_type, :target_id, :inserted_at])

    create unique_index(:agent_actions, [:action_key, :target_type, :target_id],
             where: "state IN ('queued', 'running')",
             name: :agent_actions_one_active_per_target
           )

    alter table(:agent_runs) do
      add :agent_action_id, references(:agent_actions, on_delete: :nilify_all)
    end

    create index(:agent_runs, [:agent_action_id])
  end
end
