defmodule PtcManager.Operations.AuditEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :actor, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :details, :map, default: %{}

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(audit_event, attrs) do
    audit_event
    |> cast(attrs, [:actor, :action, :target_type, :target_id, :details])
    |> validate_required([:actor, :action, :target_type, :target_id, :details])
  end
end
