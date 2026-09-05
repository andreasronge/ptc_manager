defmodule PtcManager.Repo.Migrations.AddJobStopReportToken do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :stop_report_token, :string
    end
  end
end
