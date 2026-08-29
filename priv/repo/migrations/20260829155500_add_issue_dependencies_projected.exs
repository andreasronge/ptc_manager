defmodule PtcManager.Repo.Migrations.AddIssueDependenciesProjected do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :dependencies_projected, :boolean, null: false, default: false
    end
  end
end
