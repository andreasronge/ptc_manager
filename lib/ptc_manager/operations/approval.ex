defmodule PtcManager.Operations.Approval do
  use Ecto.Schema
  import Ecto.Changeset

  schema "approvals" do
    field :decision, :string
    field :actor, :string
    field :source_updated_at, :utc_datetime_usec
    field :source_digest, :string
    field :proposal_digest, :string
    field :approved_at, :utc_datetime_usec

    belongs_to :proposal, PtcManager.Operations.Proposal
    has_one :job, PtcManager.Operations.Job

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [
      :proposal_id,
      :decision,
      :actor,
      :source_updated_at,
      :source_digest,
      :proposal_digest,
      :approved_at
    ])
    |> validate_required([
      :proposal_id,
      :decision,
      :actor,
      :source_updated_at,
      :source_digest,
      :proposal_digest,
      :approved_at
    ])
    |> validate_inclusion(:decision, ["start_implementation"])
  end
end
