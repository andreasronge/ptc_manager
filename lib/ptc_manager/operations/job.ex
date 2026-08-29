defmodule PtcManager.Operations.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open publish_blocked done failed cancelled lost)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "jobs" do
    field :kind, :string, default: "implementation"
    field :state, :string, default: "queued"
    field :fencing_token, :integer, default: 0
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :branch_name, :string
    field :last_error, :string
    field :reconciling_at, :utc_datetime_usec
    field :absence_observed_at, :utc_datetime_usec
    field :result_base_sha, :string
    field :result_head_sha, :string
    field :result_diff_digest, :string
    field :result_commit_count, :integer
    field :result_verified_at, :utc_datetime_usec
    field :result_checked_at, :utc_datetime_usec
    field :result_attempt_token, :string
    field :result_attempt_expires_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :issue, PtcManager.Operations.Issue
    belongs_to :approval, PtcManager.Operations.Approval
    has_many :agent_runs, PtcManager.Operations.AgentRun
    has_one :pr_publication, PtcManager.Operations.PrPublication

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :approval_id,
      :kind,
      :state,
      :fencing_token,
      :lease_owner,
      :lease_expires_at,
      :started_at,
      :ended_at,
      :branch_name,
      :last_error,
      :reconciling_at,
      :absence_observed_at,
      :result_base_sha,
      :result_head_sha,
      :result_diff_digest,
      :result_commit_count,
      :result_verified_at,
      :result_checked_at,
      :result_attempt_token,
      :result_attempt_expires_at
    ])
    |> validate_required([
      :repository_id,
      :issue_id,
      :approval_id,
      :kind,
      :state,
      :fencing_token
    ])
    |> validate_inclusion(:kind, ["implementation"])
    |> validate_inclusion(:state, @states)
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> validate_length(:lease_owner, max: 120)
    |> validate_length(:branch_name, max: 240)
    |> validate_length(:last_error, max: 500)
    |> validate_length(:result_attempt_token, max: 64)
    |> validate_format(:result_base_sha, @sha)
    |> validate_format(:result_head_sha, @sha)
    |> validate_format(:result_diff_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:result_commit_count, greater_than: 0)
    |> unique_constraint(:issue_id, name: :jobs_one_active_per_issue)
    |> unique_constraint(:issue_id, name: :jobs_issue_id_index)
  end
end
