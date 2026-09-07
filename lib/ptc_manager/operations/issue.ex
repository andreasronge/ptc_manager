defmodule PtcManager.Operations.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  schema "issues" do
    field :number, :integer
    field :title, :string
    field :html_url, :string
    field :body, :string, default: ""
    field :state, :string, default: "open"
    field :github_state_reason, :string
    field :workflow_label, :string
    field :workflow_label_conflict, :boolean, default: false
    field :github_assignees, :map, default: %{"logins" => []}
    field :github_assignment_projected, :boolean, default: false
    field :dependency_overflow, :boolean, default: false
    field :dependency_unknown_count, :integer, default: 0
    field :dependencies_projected, :boolean, default: false
    field :body_digest, :string
    field :content_digest, :string
    field :github_author_login, :string
    field :github_labels, :map, default: %{"names" => []}
    field :github_comment_count, :integer
    field :comments_checked_at, :utc_datetime_usec
    field :github_created_at, :utc_datetime_usec
    field :github_updated_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    has_many :proposals, PtcManager.Operations.Proposal
    has_many :jobs, PtcManager.Operations.Job
    has_many :dependencies, PtcManager.Operations.IssueDependency

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :repository_id,
      :number,
      :title,
      :html_url,
      :body,
      :state,
      :github_state_reason,
      :workflow_label,
      :workflow_label_conflict,
      :github_assignees,
      :github_assignment_projected,
      :dependency_overflow,
      :dependency_unknown_count,
      :dependencies_projected,
      :body_digest,
      :content_digest,
      :github_author_login,
      :github_labels,
      :github_comment_count,
      :comments_checked_at,
      :github_created_at,
      :github_updated_at
    ])
    |> validate_required([
      :repository_id,
      :number,
      :title,
      :html_url,
      :state,
      :body_digest,
      :content_digest,
      :github_updated_at
    ])
    |> validate_number(:github_comment_count, greater_than_or_equal_to: 0)
    |> validate_number(:number, greater_than: 0)
    |> validate_number(:dependency_unknown_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:state, ["open", "closed"])
    |> validate_inclusion(:workflow_label, ["ptc:ready", "ptc:blocked", "ptc:needs-decision"])
    |> unique_constraint([:repository_id, :number])
  end
end
