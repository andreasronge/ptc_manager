defmodule PtcManager.Collections.Member do
  @moduledoc """
  One member the maintainer authorized a run to deliver.

  GitHub's sub-issue list is compared against these rows on every reconcile;
  a difference is structural drift and pauses the run until the maintainer
  accepts it. `added_by` records who widened the authorization: the start, a
  handoff or close-out that created the issue, or an explicit acceptance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @added_by ~w(start handoff closeout accept)

  schema "collection_run_members" do
    field :issue_number, :integer
    field :added_by, :string

    belongs_to :run, PtcManager.Collections.Run
    belongs_to :issue, PtcManager.Operations.Issue

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:run_id, :issue_number, :issue_id, :added_by])
    |> validate_required([:run_id, :issue_number, :added_by])
    |> validate_number(:issue_number, greater_than: 0)
    |> validate_inclusion(:added_by, @added_by)
    |> unique_constraint([:run_id, :issue_number])
  end
end
