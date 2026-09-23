defmodule PtcManager.Repo.Migrations.CreateToolchainChecks do
  use Ecto.Migration

  def change do
    create table(:toolchain_checks) do
      add :program, :string, null: false
      add :version, :string
      add :status, :string, null: false
      add :error, :string
      add :checked_at, :utc_datetime_usec, null: false
    end

    create unique_index(:toolchain_checks, [:program])
  end
end
