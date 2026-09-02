defmodule PtcManager.MachineUsage.Sample do
  @moduledoc "One recorded observation of host load and occupied slots."

  use Ecto.Schema
  import Ecto.Changeset

  schema "machine_usage_samples" do
    field :sampled_at, :utc_datetime
    field :cpu_percent, :float
    field :memory_percent, :float
    field :disk_percent, :float
    field :load_one, :float
    field :active_light_agents, :integer, default: 0
    field :active_heavy_agents, :integer, default: 0
    field :active_operations, :integer, default: 0
  end

  def changeset(sample, attrs) do
    sample
    |> cast(attrs, [
      :sampled_at,
      :cpu_percent,
      :memory_percent,
      :disk_percent,
      :load_one,
      :active_light_agents,
      :active_heavy_agents,
      :active_operations
    ])
    |> validate_required([
      :sampled_at,
      :active_light_agents,
      :active_heavy_agents,
      :active_operations
    ])
    |> validate_number(:cpu_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:memory_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:disk_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:load_one, greater_than_or_equal_to: 0)
    |> validate_number(:active_light_agents, greater_than_or_equal_to: 0)
    |> validate_number(:active_heavy_agents, greater_than_or_equal_to: 0)
    |> validate_number(:active_operations, greater_than_or_equal_to: 0)
  end
end
