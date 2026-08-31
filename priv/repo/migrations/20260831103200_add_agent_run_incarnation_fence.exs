defmodule PtcManager.Repo.Migrations.AddAgentRunIncarnationFence do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :worker_incarnation_id, :string
      add :herdr_incarnation_id, :string
      add :coordinator_incarnation_id, :string
    end
  end
end
