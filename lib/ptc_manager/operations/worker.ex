defmodule PtcManager.Operations.Worker do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workers" do
    field :worker_key, :string
    field :name, :string
    field :status, :string, default: "offline"
    field :capabilities, :map, default: %{}
    field :last_heartbeat_at, :utc_datetime_usec

    has_many :agent_runs, PtcManager.Operations.AgentRun
    has_many :worktree_allocations, PtcManager.Operations.WorktreeAllocation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(worker, attrs) do
    worker
    |> cast(attrs, [:worker_key, :name, :status, :capabilities, :last_heartbeat_at])
    |> validate_required([:worker_key, :name, :status, :capabilities])
    |> validate_inclusion(:status, ["online", "degraded", "offline"])
    |> unique_constraint(:worker_key)
  end
end
