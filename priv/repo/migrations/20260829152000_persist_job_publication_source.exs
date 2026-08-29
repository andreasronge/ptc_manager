defmodule PtcManager.Repo.Migrations.PersistJobPublicationSource do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :publication_source, :string
    end
  end
end
