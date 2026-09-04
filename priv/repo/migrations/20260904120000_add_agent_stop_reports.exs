defmodule PtcManager.Repo.Migrations.AddAgentStopReports do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :stop_report, :map
      add :stop_reported_at, :utc_datetime_usec
      add :stop_acknowledged_at, :utc_datetime_usec
    end

    create index(:jobs, [:stop_reported_at], where: "stop_acknowledged_at IS NULL")
  end
end
