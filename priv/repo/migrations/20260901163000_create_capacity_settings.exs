defmodule PtcManager.Repo.Migrations.CreateCapacitySettings do
  use Ecto.Migration

  def change do
    create table(:capacity_settings) do
      add :light_agent_capacity, :integer, null: false
      add :heavy_agent_capacity, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end
  end
end
