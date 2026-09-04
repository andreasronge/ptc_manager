defmodule PtcManager.Operations.Approval do
  @moduledoc """
  One maintainer decision to start implementing one issue.

  A prepared approval freezes the proposal it was made from. A direct one has no
  proposal at all: the maintainer looked at the issue and decided it is small
  enough that the preparation round would only be overhead. Every other
  deterministic gate is identical.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @decisions ~w(start_implementation start_implementation_direct)

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
    |> validate_required([:decision, :actor, :source_updated_at, :source_digest, :approved_at])
    |> validate_inclusion(:decision, @decisions)
    |> require_proposal()
  end

  defp require_proposal(changeset) do
    if get_field(changeset, :decision) == "start_implementation_direct",
      do: changeset,
      else: validate_required(changeset, [:proposal_id, :proposal_digest])
  end
end
