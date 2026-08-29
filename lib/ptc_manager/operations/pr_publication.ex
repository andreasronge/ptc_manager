defmodule PtcManager.Operations.PrPublication do
  @moduledoc "Durable identity and canonical status for one implementation PR."
  use Ecto.Schema
  import Ecto.Changeset

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
    field :published_at, :utc_datetime_usec
    field :pr_state, :string
    field :pr_checked_at, :utc_datetime_usec
    field :source, :string, default: "broker"

    belongs_to :job, PtcManager.Operations.Job

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
      :published_at,
      :pr_state,
      :pr_checked_at,
      :source
    ])
    |> validate_required([
      :job_id,
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
    |> validate_inclusion(:source, ["broker"])
    |> validate_number(:pr_number, greater_than: 0)
    |> validate_length(:idempotency_key, is: 64)
    |> validate_length(:branch_name, max: 240)
    |> validate_length(:attempt_token, max: 64)
    |> validate_length(:last_error, max: 500)
    |> validate_length(:pr_url, max: 500)
    |> validate_inclusion(:pr_state, ["open", "merged", "closed"])
    |> validate_format(:idempotency_key, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:base_sha, @sha)
    |> validate_format(:head_sha, @sha)
    |> validate_format(:remote_head_sha, @sha)
    |> validate_format(:diff_digest, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:job_id)
    |> unique_constraint(:idempotency_key)
  end
end
