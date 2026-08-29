defmodule PtcManager.Operations.WorktreeAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(reserved active awaiting_pr warm reclaimable attention terminal cleaning removed)
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
      :last_error
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
    |> unique_constraint(:job_id)
  end
end
