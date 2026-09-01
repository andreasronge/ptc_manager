defmodule PtcManager.Operations.CapacityChange do
  use Ecto.Schema
  import Ecto.Changeset

  schema "capacity_changes" do
    field :worker_incarnation_id, :string
    field :light_agent_capacity, :integer
    field :heavy_agent_capacity, :integer
    field :operation_capacity, :integer
    field :effective_at, :utc_datetime_usec

    belongs_to :worker, PtcManager.Operations.Worker

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :worker_id,
      :worker_incarnation_id,
      :light_agent_capacity,
      :heavy_agent_capacity,
      :operation_capacity,
      :effective_at
    ])
    |> validate_required([
      :light_agent_capacity,
      :heavy_agent_capacity,
      :operation_capacity,
      :effective_at
    ])
    |> validate_number(:light_agent_capacity, greater_than: 0, less_than_or_equal_to: 8)
    |> validate_number(:heavy_agent_capacity, greater_than: 0, less_than_or_equal_to: 8)
    |> validate_number(:operation_capacity, greater_than: 0, less_than_or_equal_to: 8)
  end
end
