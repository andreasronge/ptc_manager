defmodule PtcManager.Repo.Migrations.AddReadOnlyIntegrationFields do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :local_path, :string
      add :sync_status, :string, null: false, default: "never"
      add :last_synced_at, :utc_datetime_usec
      add :last_sync_error, :text
    end

    alter table(:issues) do
      add :body, :text, null: false, default: ""
    end

    alter table(:agent_runs) do
      add :external_key, :string
    end

    create index(:agent_runs, [:worker_id, :external_key])
  end
end
