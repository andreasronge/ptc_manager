defmodule PtcManager.Operations.Repository do
  use Ecto.Schema
  import Ecto.Changeset

  schema "repositories" do
    field :github_owner, :string
    field :github_name, :string
    field :default_branch, :string, default: "main"
    field :enabled, :boolean, default: true
    field :local_path, :string
    field :sync_status, :string, default: "never"
    field :last_synced_at, :utc_datetime_usec
    field :last_sync_error, :string
    field :required_pre_pr_reviews, :integer, default: 2
    field :implementation_test_command, :string

    has_many :issues, PtcManager.Operations.Issue
    has_many :jobs, PtcManager.Operations.Job
    has_many :agent_actions, PtcManager.Operations.AgentAction
    has_many :pr_publications, PtcManager.Operations.PrPublication

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [
      :github_owner,
      :github_name,
      :default_branch,
      :enabled,
      :local_path,
      :sync_status,
      :last_synced_at,
      :last_sync_error,
      :required_pre_pr_reviews,
      :implementation_test_command
    ])
    |> validate_required([:github_owner, :github_name, :default_branch, :enabled])
    |> validate_inclusion(:sync_status, ["never", "syncing", "ok", "error"])
    |> validate_number(:required_pre_pr_reviews,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10
    )
    |> validate_length(:implementation_test_command, max: 2_000)
    |> unique_constraint([:github_owner, :github_name])
  end
end
