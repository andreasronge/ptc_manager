defmodule PtcManager.Reviews.Round do
  use Ecto.Schema
  import Ecto.Changeset

  schema "review_rounds" do
    belongs_to :job, PtcManager.Operations.Job
    field :fencing_token, :integer
    field :generation, :integer
    field :number, :integer
    field :request_id, :string
    field :state, :string
    field :head_sha, :string
    field :base_sha, :string
    field :diff_digest, :string
    field :input, :map
    field :result, :map
    field :error, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(round, attrs) do
    round
    |> cast(attrs, [
      :job_id,
      :fencing_token,
      :generation,
      :number,
      :request_id,
      :state,
      :head_sha,
      :base_sha,
      :diff_digest,
      :input,
      :result,
      :error,
      :expires_at
    ])
    |> validate_required([
      :job_id,
      :fencing_token,
      :generation,
      :number,
      :request_id,
      :state,
      :head_sha,
      :base_sha,
      :diff_digest,
      :input,
      :expires_at
    ])
    |> unique_constraint([:job_id, :request_id])
  end
end
