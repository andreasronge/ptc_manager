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
    field :publication_source, :string
    field :required_review_count, :integer
    field :review_resume_expires_at, :utc_datetime_usec
    field :cancellation_reason, :string
    field :cancellation_action_id, :integer
    field :execution_settings, :map
    field :review_state, :string
    field :reviewed_head_sha, :string
    field :review_continuation_instructions, :string
    field :review_recovery_expires_at, :utc_datetime_usec
    field :review_resume_mode, :string
    field :review_generation, :integer, default: 0
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
    field :pre_publication_bootstrap_command, :string
    field :pre_publication_bootstrap_timeout_ms, :integer
    field :pre_publication_command, :string
    field :pre_publication_timeout_ms, :integer
    field :pre_publication_config_digest, :string
    field :pre_publication_status, :string
    field :pre_publication_verified_sha, :string
    field :pre_publication_exit_status, :integer
    field :pre_publication_output, :string
    field :pre_publication_duration_ms, :integer
    field :pre_publication_verified_at, :utc_datetime_usec
    field :prompt_instructions, :string
    field :stop_report_token, :string
    field :stop_report, :map
    field :stop_reported_at, :utc_datetime_usec
    field :stop_acknowledged_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :issue, PtcManager.Operations.Issue
    belongs_to :approval, PtcManager.Operations.Approval
    belongs_to :automation_definition_version, PtcManager.Automations.DefinitionVersion
    has_many :agent_runs, PtcManager.Operations.AgentRun
    has_many :resource_operations, PtcManager.Operations.ResourceOperation
    has_one :pr_publication, PtcManager.Operations.PrPublication
    has_one :worktree_allocation, PtcManager.Operations.WorktreeAllocation
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :approval_id,
      :automation_definition_version_id,
      :kind,
      :state,
      :fencing_token,
      :lease_owner,
      :lease_expires_at,
      :started_at,
      :ended_at,
      :branch_name,
      :publication_source,
      :required_review_count,
      :review_resume_expires_at,
      :cancellation_reason,
      :cancellation_action_id,
      :execution_settings,
      :review_state,
      :reviewed_head_sha,
      :review_recovery_expires_at,
      :review_resume_mode,
      :review_generation,
      :review_continuation_instructions,
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
      :result_attempt_expires_at,
      :pre_publication_bootstrap_command,
      :pre_publication_bootstrap_timeout_ms,
      :pre_publication_command,
      :pre_publication_timeout_ms,
      :pre_publication_config_digest,
      :pre_publication_status,
      :pre_publication_verified_sha,
      :pre_publication_exit_status,
      :pre_publication_output,
      :pre_publication_duration_ms,
      :pre_publication_verified_at,
      :prompt_instructions,
      :stop_report_token,
      :stop_report,
      :stop_reported_at,
      :stop_acknowledged_at
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
    |> validate_inclusion(:publication_source, ["broker", "agent"])
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> validate_number(:required_review_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_length(:lease_owner, max: 120)
    |> validate_length(:branch_name, max: 240)
    |> validate_length(:last_error, max: 500)
    |> validate_length(:result_attempt_token, max: 64)
    |> validate_length(:pre_publication_bootstrap_command, max: 2_000)
    |> validate_length(:pre_publication_command, max: 2_000)
    |> validate_length(:pre_publication_output, max: 65_536)
    |> validate_length(:prompt_instructions, max: 20_000)
    |> validate_length(:review_continuation_instructions, max: 4_000)
    |> validate_inclusion(:pre_publication_status, ["pending", "running", "passed", "failed"])
    |> validate_number(:pre_publication_timeout_ms,
      greater_than: 0,
      less_than_or_equal_to: 86_400_000
    )
    |> validate_number(:pre_publication_bootstrap_timeout_ms,
      greater_than: 0,
      less_than_or_equal_to: 86_400_000
    )
    |> validate_number(:pre_publication_exit_status, greater_than_or_equal_to: 0)
    |> validate_number(:pre_publication_duration_ms, greater_than_or_equal_to: 0)
    |> validate_format(:pre_publication_config_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:pre_publication_verified_sha, @sha)
    |> validate_format(:result_base_sha, @sha)
    |> validate_format(:result_head_sha, @sha)
    |> validate_format(:result_diff_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_number(:result_commit_count, greater_than: 0)
    |> unique_constraint(:issue_id, name: :jobs_one_active_per_issue)
    |> unique_constraint(:issue_id, name: :jobs_issue_id_index)
  end
end
