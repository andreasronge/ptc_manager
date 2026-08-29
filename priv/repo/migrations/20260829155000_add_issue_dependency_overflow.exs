defmodule PtcManager.Repo.Migrations.AddIssueDependencyOverflow do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :dependency_overflow, :boolean, null: false, default: false
    end
  end
end
