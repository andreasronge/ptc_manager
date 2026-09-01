defmodule PtcManager.Repo.Migrations.ScopeActiveActionUniqueness do
  use Ecto.Migration

  def up do
    drop unique_index(:agent_actions, [:target_type, :target_id],
           name: :agent_actions_one_active_per_target
         )

    create unique_index(:agent_actions, [:target_type, :target_id],
             where:
               "state IN ('queued', 'running', 'sync_pending') AND target_type IN ('issue', 'pull_request')",
             name: :agent_actions_one_active_per_target
           )

    create unique_index(:agent_actions, [:action_key, :target_type, :target_id],
             where:
               "state IN ('queued', 'running', 'sync_pending') AND target_type = 'repository'",
             name: :agent_actions_one_active_repository_action
           )
  end

  def down do
    drop unique_index(:agent_actions, [:target_type, :target_id],
           name: :agent_actions_one_active_per_target
         )

    drop unique_index(:agent_actions, [:action_key, :target_type, :target_id],
           name: :agent_actions_one_active_repository_action
         )

    create unique_index(:agent_actions, [:target_type, :target_id],
             where: "state IN ('queued', 'running', 'sync_pending')",
             name: :agent_actions_one_active_per_target
           )
  end
end
