defmodule PtcManager.Operations.IssueDependency do
  use Ecto.Schema
  import Ecto.Changeset

  schema "issue_dependencies" do
    field :blocking_issue_number, :integer
    field :blocking_repository_full_name, :string
    field :blocking_github_id, :integer
    field :blocking_node_id, :string
    field :blocking_title, :string
    field :blocking_html_url, :string
    field :blocking_state, :string
    field :blocking_state_reason, :string
    field :lookup_state, :string, default: "pending"
    field :lookup_checked_at, :utc_datetime_usec

    belongs_to :issue, PtcManager.Operations.Issue
    belongs_to :blocking_issue, PtcManager.Operations.Issue
    belongs_to :blocking_repository, PtcManager.Operations.Repository

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [
      :issue_id,
      :blocking_issue_id,
      :blocking_repository_id,
      :blocking_repository_full_name,
      :blocking_github_id,
      :blocking_node_id,
      :blocking_issue_number,
      :blocking_title,
      :blocking_html_url,
      :blocking_state,
      :blocking_state_reason,
      :lookup_state,
      :lookup_checked_at
    ])
    |> validate_required([
      :issue_id,
      :blocking_repository_full_name,
      :blocking_issue_number,
      :lookup_state
    ])
    |> validate_number(:blocking_issue_number, greater_than: 0)
    |> validate_inclusion(:lookup_state, ["pending", "resolved", "missing", "pull_request"])
    |> validate_inclusion(:blocking_state, ["open", "closed"])
    |> unique_constraint(
      [:issue_id, :blocking_repository_full_name, :blocking_issue_number],
      name: :issue_dependencies_exact_blocker_index
    )
  end
end
