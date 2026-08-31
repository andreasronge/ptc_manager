defmodule PtcManager.Repo.Migrations.EnforceUniqueRepositoryCheckoutPaths do
  use Ecto.Migration

  def change do
    PtcManager.Repository.CheckoutMigrationAudit.ensure_no_duplicate_local_paths!(repo())
    create unique_index(:repositories, [:local_path], where: "local_path IS NOT NULL")
  end
end
