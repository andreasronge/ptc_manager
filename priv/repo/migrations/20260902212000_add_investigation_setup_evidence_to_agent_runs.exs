defmodule PtcManager.Repo.Migrations.AddInvestigationSetupEvidenceToAgentRuns do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :workspace_setup_state, :string
      add :workspace_setup_script, :string
      add :workspace_setup_source_sha, :string
      add :workspace_setup_started_at, :utc_datetime_usec
      add :workspace_setup_ended_at, :utc_datetime_usec
      add :workspace_setup_duration_ms, :integer
      add :workspace_setup_exit_status, :integer
      add :workspace_setup_output, :text
      add :workspace_setup_output_truncated, :boolean, null: false, default: false
      add :workspace_setup_cache_state, :string
      add :workspace_setup_phase_durations, :map, null: false, default: %{}
      add :workspace_setup_error, :string
    end
  end
end
