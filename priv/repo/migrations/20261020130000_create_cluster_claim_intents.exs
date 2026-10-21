defmodule PtcManager.Repo.Migrations.CreateClusterClaimIntents do
  use Ecto.Migration

  def change do
    create table(:cluster_claim_intents) do
      add :repository_key, :string, null: false
      add :token, :string, null: false
      add :actor, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cluster_claim_intents, [:repository_key])
  end
end
