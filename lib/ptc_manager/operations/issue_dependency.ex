defmodule PtcManager.Operations.IssueDependency do
  use Ecto.Schema
  import Ecto.Changeset

  schema "issue_dependencies" do
    field :blocking_issue_number, :integer
    field :lookup_state, :string, default: "pending"
    field :lookup_checked_at, :utc_datetime_usec

    belongs_to :issue, PtcManager.Operations.Issue
    belongs_to :blocking_issue, PtcManager.Operations.Issue

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [
      :issue_id,
      :blocking_issue_id,
      :blocking_issue_number,
      :lookup_state,
      :lookup_checked_at
    ])
    |> validate_required([:issue_id, :blocking_issue_number, :lookup_state])
    |> validate_number(:blocking_issue_number, greater_than: 0)
    |> validate_inclusion(:lookup_state, ["pending", "resolved", "missing", "pull_request"])
    |> unique_constraint([:issue_id, :blocking_issue_number])
  end
end
