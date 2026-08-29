defmodule PtcManager.Operations.Proposal do
  use Ecto.Schema
  import Ecto.Changeset

  @risks ~w(low medium high)
  @readiness ~w(ready needs_information needs_breakdown outdated duplicate)

  schema "proposals" do
    field :source_updated_at, :utc_datetime_usec
    field :source_digest, :string
    field :proposal_digest, :string
    field :plain_summary, :string
    field :why_it_matters, :string
    field :scope, :string
    field :risk, :string
    field :readiness, :string
    field :technical_evidence, :string

    belongs_to :issue, PtcManager.Operations.Issue
    has_many :approvals, PtcManager.Operations.Approval

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :issue_id,
      :source_updated_at,
      :source_digest,
      :proposal_digest,
      :plain_summary,
      :why_it_matters,
      :scope,
      :risk,
      :readiness,
      :technical_evidence
    ])
    |> validate_required([
      :issue_id,
      :source_updated_at,
      :source_digest,
      :proposal_digest,
      :plain_summary,
      :why_it_matters,
      :scope,
      :risk,
      :readiness,
      :technical_evidence
    ])
    |> validate_inclusion(:risk, @risks)
    |> validate_inclusion(:readiness, @readiness)
  end
end
