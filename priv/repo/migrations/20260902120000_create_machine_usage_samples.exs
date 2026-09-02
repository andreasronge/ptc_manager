defmodule PtcManager.Repo.Migrations.CreateMachineUsageSamples do
  use Ecto.Migration

  def change do
    create table(:machine_usage_samples) do
      add :sampled_at, :utc_datetime, null: false
      add :cpu_percent, :float
      add :memory_percent, :float
      add :disk_percent, :float
      add :load_one, :float
      add :active_light_agents, :integer, null: false, default: 0
      add :active_heavy_agents, :integer, null: false, default: 0
      add :active_operations, :integer, null: false, default: 0
    end

    create index(:machine_usage_samples, [:sampled_at])
  end
end
