defmodule PtcManager.Repo.Migrations.AddRepositoryWorkspaceSetup do
  use Ecto.Migration

  # Workspace setup moves out of .ptc-manager.yml. Every repository registered so
  # far ships the same entrypoint; 30 minutes is the largest timeout any of them
  # used (ptc_runner), and the maintainer can lower it per repository.
  def up do
    alter table(:repositories) do
      add :workspace_setup_command, :string
      add :workspace_setup_timeout_minutes, :integer
    end

    flush()

    execute("""
    UPDATE repositories
    SET workspace_setup_command = './scripts/ptc/bootstrap',
        workspace_setup_timeout_minutes = 30
    """)
  end

  def down do
    alter table(:repositories) do
      remove :workspace_setup_command
      remove :workspace_setup_timeout_minutes
    end
  end
end
