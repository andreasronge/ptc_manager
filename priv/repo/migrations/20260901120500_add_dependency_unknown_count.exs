defmodule PtcManager.Repo.Migrations.AddDependencyUnknownCount do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :dependency_unknown_count, :integer, null: false, default: 0
    end
  end
end
