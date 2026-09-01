defmodule PtcManager.Operations.WorktreeAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(reserved active awaiting_pr warm waiting reclaimable attention terminal cleaning removed)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "worktree_allocations" do
    field :state, :string, default: "reserved"
    field :path, :string
    field :herdr_workspace, :string
    field :agent_kind, :string
    field :head_sha, :string
    field :pr_number, :integer
    field :pr_url, :string
    field :last_used_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :cleanup_token, :string
    field :cleanup_expires_at, :utc_datetime_usec
    field :last_error, :string
    field :worktree_created_duration_ms, :integer
    field :workspace_setup_state, :string
    field :workspace_setup_script, :string
    field :workspace_setup_source_sha, :string
    field :workspace_setup_started_at, :utc_datetime_usec
    field :workspace_setup_ended_at, :utc_datetime_usec
    field :workspace_setup_duration_ms, :integer
    field :workspace_setup_exit_status, :integer
    field :workspace_setup_output, :string
    field :workspace_setup_output_truncated, :boolean, default: false

    belongs_to :worker, PtcManager.Operations.Worker
    belongs_to :job, PtcManager.Operations.Job

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :worker_id,
      :job_id,
      :state,
      :path,
      :herdr_workspace,
      :agent_kind,
      :head_sha,
      :pr_number,
      :pr_url,
      :last_used_at,
      :removed_at,
      :cleanup_token,
      :cleanup_expires_at,
      :last_error,
      :worktree_created_duration_ms,
      :workspace_setup_state,
      :workspace_setup_script,
      :workspace_setup_source_sha,
      :workspace_setup_started_at,
      :workspace_setup_ended_at,
      :workspace_setup_duration_ms,
      :workspace_setup_exit_status,
      :workspace_setup_output,
      :workspace_setup_output_truncated
    ])
    |> validate_required([:worker_id, :job_id, :state, :last_used_at])
    |> validate_inclusion(:state, @states)
    |> validate_format(:head_sha, @sha)
    |> validate_number(:pr_number, greater_than: 0)
    |> validate_length(:path, max: 1_024)
    |> validate_length(:herdr_workspace, max: 240)
    |> validate_length(:agent_kind, max: 80)
    |> validate_length(:pr_url, max: 1_024)
    |> validate_length(:last_error, max: 500)
    |> validate_inclusion(:workspace_setup_state, ["passed", "failed"])
    |> validate_number(:worktree_created_duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:workspace_setup_duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:workspace_setup_exit_status, greater_than_or_equal_to: 0)
    |> validate_length(:workspace_setup_script, max: 2_000)
    |> validate_length(:workspace_setup_output, max: 65_536)
    |> validate_format(:workspace_setup_source_sha, @sha)
    |> unique_constraint(:job_id)
  end
end
