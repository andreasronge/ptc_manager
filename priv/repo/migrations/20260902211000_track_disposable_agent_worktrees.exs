defmodule PtcManager.Repo.Migrations.TrackDisposableAgentWorktrees do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :disposable_worktree_path, :string
      add :disposable_worktree_branch, :string
      add :disposable_cleanup_state, :string
      add :disposable_cleanup_token, :string
      add :disposable_cleanup_expires_at, :utc_datetime_usec
    end

    create index(:agent_runs, [:disposable_cleanup_state])
  end
end
