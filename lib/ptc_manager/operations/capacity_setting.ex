defmodule PtcManager.Operations.CapacitySetting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "capacity_settings" do
    field :light_agent_capacity, :integer
    field :heavy_agent_capacity, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:light_agent_capacity, :heavy_agent_capacity])
    |> validate_required([:light_agent_capacity, :heavy_agent_capacity])
    |> validate_number(:light_agent_capacity, greater_than: 0, less_than_or_equal_to: 8)
    |> validate_number(:heavy_agent_capacity, greater_than: 0, less_than_or_equal_to: 8)
  end
end
