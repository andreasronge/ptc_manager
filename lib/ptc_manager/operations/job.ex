defmodule PtcManager.Operations.Job do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued starting working idle blocked reconciling awaiting_reconciliation done failed cancelled lost)

  schema "jobs" do
    field :kind, :string, default: "implementation"
    field :state, :string, default: "queued"
    field :fencing_token, :integer, default: 0
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :branch_name, :string
    field :last_error, :string
    field :reconciling_at, :utc_datetime_usec
    field :absence_observed_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :issue, PtcManager.Operations.Issue
    belongs_to :approval, PtcManager.Operations.Approval
    has_many :agent_runs, PtcManager.Operations.AgentRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :repository_id,
      :issue_id,
      :approval_id,
      :kind,
      :state,
      :fencing_token,
      :lease_owner,
      :lease_expires_at,
      :started_at,
      :ended_at,
      :branch_name,
      :last_error,
      :reconciling_at,
      :absence_observed_at
    ])
    |> validate_required([
      :repository_id,
      :issue_id,
      :approval_id,
      :kind,
      :state,
      :fencing_token
    ])
    |> validate_inclusion(:kind, ["implementation"])
    |> validate_inclusion(:state, @states)
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> validate_length(:lease_owner, max: 120)
    |> validate_length(:branch_name, max: 240)
    |> validate_length(:last_error, max: 500)
    |> unique_constraint(:issue_id, name: :jobs_one_active_per_issue)
    |> unique_constraint(:issue_id, name: :jobs_issue_id_index)
  end
end
