defmodule PtcManager.Repo.Migrations.TrackProviderSessionArchival do
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add :provider_sessions_archived, :boolean, default: false, null: false
    end
  end
end
