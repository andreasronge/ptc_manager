defmodule PtcManager.Collections.Step do
  @moduledoc """
  One automatic effect a collection run has spent, recorded once.

  The `(run, kind, scope)` uniqueness is the bound: a step and the effect it
  records are written in one transaction, so a row exists if and only if the
  effect happened, and a concurrent reconciler that loses the race inserts
  nothing. The scope names exactly what the bound covers, for example a job
  id for a retry or a publication id and head for a merge.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(
    admit
    retry
    ask_on_issue
    review_continue
    review_retry
    merge
    handoff
    closeout
    escalation
    override
  )

  schema "collection_run_steps" do
    field :kind, :string
    field :scope, :string
    field :actor, :string

    belongs_to :run, PtcManager.Collections.Run
    belongs_to :agent_action, PtcManager.Operations.AgentAction
    belongs_to :job, PtcManager.Operations.Job

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:run_id, :kind, :scope, :agent_action_id, :job_id, :actor])
    |> validate_required([:run_id, :kind, :scope, :actor])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:scope, max: 200)
    |> unique_constraint([:run_id, :kind, :scope])
  end
end
