defmodule PtcManager.Repo.Migrations.AddRepositoryMachineRequirements do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :machine_requirements, :map, default: %{"tools" => []}
    end
  end
end
