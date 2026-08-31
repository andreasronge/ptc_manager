defmodule PtcManager.Operations.Worker do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workers" do
    field :worker_key, :string
    field :name, :string
    field :status, :string, default: "offline"
    field :capabilities, :map, default: %{}
    field :last_heartbeat_at, :utc_datetime_usec
    field :worker_incarnation_id, :string
    field :previous_worker_incarnation_id, :string
    field :herdr_incarnation_id, :string
    field :previous_herdr_incarnation_id, :string
    field :snapshot_sequence, :integer, default: 0
    field :healthy_snapshot_count, :integer, default: 0
    field :restart_reason, :string
    field :incarnation_changed_at, :utc_datetime_usec
    field :coordinator_incarnation_id, :string

    has_many :agent_runs, PtcManager.Operations.AgentRun
    has_many :worktree_allocations, PtcManager.Operations.WorktreeAllocation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [
      :worker_key,
      :name,
      :status,
      :capabilities,
      :last_heartbeat_at,
      :worker_incarnation_id,
      :previous_worker_incarnation_id,
      :herdr_incarnation_id,
      :previous_herdr_incarnation_id,
      :snapshot_sequence,
      :healthy_snapshot_count,
      :restart_reason,
      :incarnation_changed_at,
      :coordinator_incarnation_id
    ])
    |> validate_required([:worker_key, :name, :status, :capabilities])
    |> validate_inclusion(:status, ["online", "degraded", "offline"])
    |> validate_number(:snapshot_sequence, greater_than_or_equal_to: 0)
    |> validate_number(:healthy_snapshot_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:worker_key)
  end
end
