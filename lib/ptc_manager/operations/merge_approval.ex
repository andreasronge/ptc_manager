defmodule PtcManager.Operations.MergeApproval do
  @moduledoc "A human merge approval bound to an immutable private PR analysis."

  use Ecto.Schema
  import Ecto.Changeset

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "merge_approvals" do
    field :decision, :string, default: "approve"
    field :actor, :string
    field :base_repository, :string
    field :base_ref, :string
    field :reviewed_base_sha, :string
    field :head_sha, :string
    field :diff_digest, :string
    field :approved_at, :utc_datetime_usec

    belongs_to :publication, PtcManager.Operations.PrPublication
    belongs_to :pr_analysis, PtcManager.Operations.PrAnalysis

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [
      :publication_id,
      :pr_analysis_id,
      :decision,
      :actor,
      :base_repository,
      :base_ref,
      :reviewed_base_sha,
      :head_sha,
      :diff_digest,
      :approved_at
    ])
    |> validate_required([
      :publication_id,
      :pr_analysis_id,
      :decision,
      :actor,
      :base_repository,
      :base_ref,
      :reviewed_base_sha,
      :head_sha,
      :diff_digest,
      :approved_at
    ])
    |> validate_inclusion(:decision, ["approve"])
    |> validate_length(:actor, max: 120)
    |> validate_format(:reviewed_base_sha, @sha)
    |> validate_format(:head_sha, @sha)
    |> validate_format(:diff_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:pr_analysis_id)
  end
end
