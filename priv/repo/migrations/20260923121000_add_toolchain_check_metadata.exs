defmodule PtcManager.Repo.Migrations.AddToolchainCheckMetadata do
  use Ecto.Migration

  def change do
    alter table(:toolchain_checks) do
      add :digest, :string
      add :protocol, :integer
    end
  end
end
