defmodule PtcManager.Repo.Migrations.CreateCommitIdentities do
  use Ecto.Migration

  def change do
    create table(:commit_identities) do
      add :owner, :string, null: false, default: ""
      add :name, :string, null: false
      add :email, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:commit_identities, [:owner])
  end
end
