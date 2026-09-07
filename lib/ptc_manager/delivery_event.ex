defmodule PtcManager.DeliveryEvent do
  @moduledoc "Immutable lifecycle snapshots captured by SQLite, including fenced bulk updates."
  use Ecto.Schema

  schema "delivery_events" do
    belongs_to :job, PtcManager.Operations.Job
    field :before_state, :map
    field :after_state, :map
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
