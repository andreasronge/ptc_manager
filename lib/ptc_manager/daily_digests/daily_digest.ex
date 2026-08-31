defmodule PtcManager.DailyDigests.DailyDigest do
  use Ecto.Schema
  import Ecto.Changeset

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "daily_digests" do
    field :digest_date, :date
    field :window_started_at, :utc_datetime_usec
    field :window_ended_at, :utc_datetime_usec
    field :time_zone, :string
    field :title, :string
    field :summary, :string
    field :markdown, :string
    field :source_head_sha, :string
    field :change_count, :integer, default: 0
    field :pull_request_numbers, :map, default: %{"numbers" => []}
    field :published_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :agent_action, PtcManager.Operations.AgentAction

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(digest, attrs) do
    digest
    |> cast(attrs, [
      :repository_id,
      :agent_action_id,
      :digest_date,
      :window_started_at,
      :window_ended_at,
      :time_zone,
      :title,
      :summary,
      :markdown,
      :source_head_sha,
      :change_count,
      :pull_request_numbers,
      :published_at
    ])
    |> validate_required([
      :repository_id,
      :digest_date,
      :window_started_at,
      :window_ended_at,
      :time_zone,
      :change_count,
      :pull_request_numbers
    ])
    |> validate_number(:change_count, greater_than_or_equal_to: 0)
    |> validate_length(:time_zone, max: 120)
    |> validate_length(:title, max: 180)
    |> validate_length(:summary, max: 4_000)
    |> validate_length(:markdown, max: 40_000)
    |> validate_format(:source_head_sha, @sha)
    |> validate_window()
    |> unique_constraint([:repository_id, :digest_date])
    |> unique_constraint(:agent_action_id)
  end

  defp validate_window(changeset) do
    start_at = get_field(changeset, :window_started_at)
    end_at = get_field(changeset, :window_ended_at)

    if start_at && end_at && DateTime.compare(start_at, end_at) != :lt,
      do: add_error(changeset, :window_ended_at, "must be after the start"),
      else: changeset
  end
end
