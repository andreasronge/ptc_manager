defmodule PtcManager.Collections.Run do
  @moduledoc """
  One maintainer decision that a collection may be delivered unattended.

  `active` admits, merges, hands off, and closes out. `paused` waits for the
  maintainer; the pause fields say on which member, why, and which scope an
  override would lift. `finishing` means every member is delivered and only the
  umbrella's closure, a maintainer decision, remains. `completed` and
  `cancelled` are terminal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(active paused finishing completed cancelled)
  @live_states ~w(active paused finishing)
  @pause_kinds ~w(
    child_attempt_failed
    child_review_held
    child_publication_blocked
    child_merge_blocked
    child_needs_decision
    child_closed_without_completion
    action_failed
    umbrella_needs_decision
    membership_changed
  )

  schema "collection_runs" do
    field :state, :string, default: "active"
    field :auto_merge, :boolean, default: true
    field :auto_recover, :boolean, default: true
    field :pause_sequence, :integer, default: 0
    field :pause_kind, :string
    field :pause_reason, :string
    field :pause_scope, :string
    field :paused_issue_number, :integer
    field :pause_reference_id, :integer
    field :paused_at, :utc_datetime_usec
    field :escalation_pending, :boolean, default: false
    field :end_reason, :string
    field :actor, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :issue, PtcManager.Operations.Issue
    has_many :members, PtcManager.Collections.Member, foreign_key: :run_id
    has_many :steps, PtcManager.Collections.Step, foreign_key: :run_id

    timestamps(type: :utc_datetime_usec)
  end

  def states, do: @states
  def live_states, do: @live_states
  def pause_kinds, do: @pause_kinds

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :state,
      :auto_merge,
      :auto_recover,
      :pause_sequence,
      :pause_kind,
      :pause_reason,
      :pause_scope,
      :paused_issue_number,
      :pause_reference_id,
      :paused_at,
      :escalation_pending,
      :end_reason,
      :actor,
      :started_at,
      :ended_at
    ])
    |> validate_required([:repository_id, :issue_id, :state, :actor, :started_at])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:pause_kind, @pause_kinds)
    |> validate_length(:pause_reason, max: 1_000)
    |> unique_constraint(:issue_id, name: :collection_runs_one_live_per_issue)
  end

  @doc "True while the run still holds authority over its members."
  def live?(%__MODULE__{state: state}), do: state in @live_states
end
