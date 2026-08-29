defmodule PtcManager.Operations.Repository do
  use Ecto.Schema
  import Ecto.Changeset

  schema "repositories" do
    field :github_owner, :string
    field :github_name, :string
    field :default_branch, :string, default: "main"
    field :enabled, :boolean, default: true

    has_many :issues, PtcManager.Operations.Issue
    has_many :jobs, PtcManager.Operations.Job

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:github_owner, :github_name, :default_branch, :enabled])
    |> validate_required([:github_owner, :github_name, :default_branch, :enabled])
    |> unique_constraint([:github_owner, :github_name])
  end
end
