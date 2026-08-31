defmodule PtcManager.Repo.Migrations.AddWorkerCoordinatorIncarnation do
  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :coordinator_incarnation_id, :string
    end
  end
end
