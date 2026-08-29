defmodule PtcManager.Operations.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  schema "issues" do
    field :number, :integer
    field :title, :string
    field :html_url, :string
    field :state, :string, default: "open"
    field :body_digest, :string
    field :content_digest, :string
    field :github_updated_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    has_many :proposals, PtcManager.Operations.Proposal
    has_many :jobs, PtcManager.Operations.Job

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :repository_id,
      :number,
      :title,
      :html_url,
      :state,
      :body_digest,
      :content_digest,
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
    |> validate_number(:number, greater_than: 0)
    |> validate_inclusion(:state, ["open", "closed"])
    |> unique_constraint([:repository_id, :number])
  end
end
