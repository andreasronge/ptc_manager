defmodule PtcManager.Repo.Migrations.AddWorkspaceSetupCacheEvidence do
  use Ecto.Migration

  def change do
    alter table(:worktree_allocations) do
      add :workspace_setup_cache_state, :string
      add :workspace_setup_phase_durations, :map, null: false, default: %{}
    end
  end
end
