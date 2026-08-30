defmodule PtcManager.Operations.PrPublication do
  @moduledoc "Durable identity and canonical status for one implementation PR."
  use Ecto.Schema
  import Ecto.Changeset

  alias PtcManager.GitHub.LinkedIssues

  @states ~w(queued publishing published blocked)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "pr_publications" do
    field :state, :string, default: "queued"
    field :idempotency_key, :string
    field :fencing_token, :integer
    field :branch_name, :string
    field :base_sha, :string
    field :head_sha, :string
    field :diff_digest, :string
    field :attempt_count, :integer, default: 0
    field :attempt_token, :string
    field :attempt_expires_at, :utc_datetime_usec
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :string
    field :pr_number, :integer
    field :pr_url, :string
    field :remote_head_sha, :string
    field :remote_base_sha, :string
    field :published_at, :utc_datetime_usec
    field :pr_state, :string
    field :pr_checked_at, :utc_datetime_usec
    field :source, :string, default: "broker"
    field :title, :string
    field :author_login, :string
    field :head_ref, :string
    field :head_repository, :string
    field :draft, :boolean, default: false
    field :mergeability, :string, default: "unknown"
    field :mergeable_state, :string
    field :checks_state, :string, default: "unknown"
    field :checks_total, :integer, default: 0
    field :checks_failed, :integer, default: 0
    field :checks_pending, :integer, default: 0
    field :linked_issue_numbers, :map, default: %{"numbers" => []}

    belongs_to :job, PtcManager.Operations.Job
    belongs_to :repository, PtcManager.Operations.Repository
    has_many :pr_analyses, PtcManager.Operations.PrAnalysis, foreign_key: :publication_id
    has_many :merge_approvals, PtcManager.Operations.MergeApproval, foreign_key: :publication_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(publication, attrs) do
    publication
    |> cast(attrs, [
      :job_id,
      :state,
      :idempotency_key,
      :fencing_token,
      :branch_name,
      :base_sha,
      :head_sha,
      :diff_digest,
      :attempt_count,
      :attempt_token,
      :attempt_expires_at,
      :next_attempt_at,
      :last_error,
      :pr_number,
      :pr_url,
      :remote_head_sha,
      :remote_base_sha,
      :published_at,
      :pr_state,
      :pr_checked_at,
      :source,
      :repository_id,
      :title,
      :author_login,
      :head_ref,
      :head_repository,
      :draft,
      :mergeability,
      :mergeable_state,
      :checks_state,
      :checks_total,
      :checks_failed,
      :checks_pending,
      :linked_issue_numbers
    ])
    |> validate_required([
      :state,
      :idempotency_key,
      :fencing_token,
      :branch_name,
      :base_sha,
      :head_sha,
      :diff_digest,
      :attempt_count
    ])
    |> validate_inclusion(:state, @states)
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:source, ["broker", "agent", "external"])
    |> validate_inclusion(:mergeability, ["unknown", "mergeable", "conflicting", "blocked"])
    |> validate_inclusion(:checks_state, ["unknown", "none", "pending", "success", "failure"])
    |> validate_number(:checks_total, greater_than_or_equal_to: 0)
    |> validate_number(:checks_failed, greater_than_or_equal_to: 0)
    |> validate_number(:checks_pending, greater_than_or_equal_to: 0)
    |> validate_linked_issue_numbers()
    |> validate_number(:pr_number, greater_than: 0)
    |> validate_length(:idempotency_key, is: 64)
    |> validate_length(:branch_name, max: 240)
    |> validate_length(:attempt_token, max: 64)
    |> validate_length(:last_error, max: 500)
    |> validate_length(:pr_url, max: 500)
    |> validate_length(:mergeable_state, max: 40)
    |> validate_length(:title, max: 500)
    |> validate_length(:author_login, max: 120)
    |> validate_length(:head_ref, max: 240)
    |> validate_length(:head_repository, max: 240)
    |> validate_inclusion(:pr_state, ["open", "merged", "closed"])
    |> validate_format(:idempotency_key, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:base_sha, @sha)
    |> validate_format(:head_sha, @sha)
    |> validate_format(:remote_head_sha, @sha)
    |> validate_format(:remote_base_sha, @sha)
    |> validate_format(:diff_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:job_id)
    |> unique_constraint(:idempotency_key)
    |> unique_constraint([:repository_id, :pr_number],
      name: :pr_publications_repository_pr_number_index
    )
    |> validate_publication_identity()
  end

  def managed?(%__MODULE__{source: source, job_id: job_id}),
    do: source in ["broker", "agent"] and is_integer(job_id)

  def external?(%__MODULE__{source: "external", job_id: nil}), do: true
  def external?(%__MODULE__{}), do: false

  defp validate_publication_identity(changeset) do
    if get_field(changeset, :source) == "external" do
      validate_required(changeset, [
        :repository_id,
        :title,
        :pr_number,
        :pr_url,
        :remote_head_sha,
        :remote_base_sha,
        :head_ref,
        :head_repository,
        :pr_state
      ])
    else
      validate_required(changeset, [:job_id])
    end
  end

  defp validate_linked_issue_numbers(changeset) do
    validate_change(changeset, :linked_issue_numbers, fn :linked_issue_numbers, value ->
      case value do
        %{"numbers" => numbers} when is_list(numbers) ->
          if LinkedIssues.valid?(numbers),
            do: [],
            else: [linked_issue_numbers: "must contain at most ten unique valid issue numbers"]

        _ ->
          [linked_issue_numbers: "must contain a numbers list"]
      end
    end)
  end
end
