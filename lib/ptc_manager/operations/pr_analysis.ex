defmodule PtcManager.Operations.PrAnalysis do
  @moduledoc "Private merge-readiness analysis bound to one exact pull-request version."

  use Ecto.Schema
  import Ecto.Changeset

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "pr_analyses" do
    field :outcome, :string
    field :plain_summary, :string
    field :why_it_matters, :string
    field :scope, :string
    field :risk, :string
    field :technical_evidence, :string
    field :base_repository, :string
    field :base_ref, :string
    field :reviewed_base_sha, :string
    field :head_repository, :string
    field :head_ref, :string
    field :head_sha, :string
    field :diff_digest, :string
    field :analyzed_at, :utc_datetime_usec

    belongs_to :publication, PtcManager.Operations.PrPublication
    belongs_to :agent_action, PtcManager.Operations.AgentAction
    has_one :merge_approval, PtcManager.Operations.MergeApproval

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(analysis, attrs) do
    analysis
    |> cast(attrs, [
      :publication_id,
      :agent_action_id,
      :outcome,
      :plain_summary,
      :why_it_matters,
      :scope,
      :risk,
      :technical_evidence,
      :base_repository,
      :base_ref,
      :reviewed_base_sha,
      :head_repository,
      :head_ref,
      :head_sha,
      :diff_digest,
      :analyzed_at
    ])
    |> validate_required([
      :publication_id,
      :agent_action_id,
      :outcome,
      :plain_summary,
      :why_it_matters,
      :scope,
      :risk,
      :technical_evidence,
      :base_repository,
      :base_ref,
      :reviewed_base_sha,
      :head_repository,
      :head_ref,
      :head_sha,
      :diff_digest,
      :analyzed_at
    ])
    |> validate_inclusion(:outcome, ["merge-ready", "merge-blocked", "merge-needs-decision"])
    |> validate_inclusion(:scope, ["small", "medium", "large"])
    |> validate_inclusion(:risk, ["low", "medium", "high"])
    |> validate_format(:reviewed_base_sha, @sha)
    |> validate_format(:head_sha, @sha)
    |> validate_format(:diff_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:agent_action_id)
  end
end
