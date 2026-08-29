defmodule PtcManager.Repo.Migrations.HardenAgentActionReconciliation do
  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :workflow_label_conflict, :boolean, null: false, default: false
    end

    drop unique_index(:agent_actions, [:action_key, :target_type, :target_id],
           name: :agent_actions_one_active_per_target
         )

    create unique_index(:agent_actions, [:action_key, :target_type, :target_id],
             where: "state IN ('queued', 'running', 'sync_pending')",
             name: :agent_actions_one_active_per_target
           )
  end

  def down do
    drop unique_index(:agent_actions, [:action_key, :target_type, :target_id],
           name: :agent_actions_one_active_per_target
         )

    create unique_index(:agent_actions, [:action_key, :target_type, :target_id],
             where: "state IN ('queued', 'running')",
             name: :agent_actions_one_active_per_target
           )

    alter table(:issues) do
      remove :workflow_label_conflict
    end
  end
end
