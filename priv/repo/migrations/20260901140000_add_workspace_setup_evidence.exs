defmodule PtcManager.Repo.Migrations.AddWorkspaceSetupEvidence do
  use Ecto.Migration

  def change do
    alter table(:worktree_allocations) do
      add :worktree_created_duration_ms, :integer
      add :workspace_setup_state, :string
      add :workspace_setup_script, :text
      add :workspace_setup_source_sha, :string
      add :workspace_setup_started_at, :utc_datetime_usec
      add :workspace_setup_ended_at, :utc_datetime_usec
      add :workspace_setup_duration_ms, :integer
      add :workspace_setup_exit_status, :integer
      add :workspace_setup_output, :text
      add :workspace_setup_output_truncated, :boolean, null: false, default: false
    end
  end
end
