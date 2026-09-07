defmodule PtcManager.ExecutionProfiles.Profile do
  use Ecto.Schema
  import Ecto.Changeset

  schema "execution_profiles" do
    field :name, :string
    field :kind, :string
    field :model, :string
    field :effort, :string
    field :reviewer_kind, :string
    field :reviewer_model, :string
    field :reviewer_effort, :string
    field :review_timeout_ms, :integer, default: 900_000
    field :max_reviews, :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :name,
      :kind,
      :model,
      :effort,
      :reviewer_kind,
      :reviewer_model,
      :reviewer_effort,
      :max_reviews,
      :review_timeout_ms
    ])
    |> validate_required([
      :name,
      :kind,
      :model,
      :reviewer_kind,
      :reviewer_model,
      :max_reviews,
      :review_timeout_ms
    ])
    |> validate_inclusion(:name, ~w(small standard strong))
    |> validate_inclusion(:kind, ~w(codex claude cursor))
    |> validate_inclusion(:reviewer_kind, ~w(codex claude cursor))
    |> validate_format(:model, ~r/\A(?=.{1,120}\z)[a-zA-Z0-9][a-zA-Z0-9._:-]*(?:\[1m\])?\z/)
    |> validate_format(
      :reviewer_model,
      ~r/\A(?=.{1,120}\z)[a-zA-Z0-9][a-zA-Z0-9._:-]*(?:\[1m\])?\z/
    )
    |> validate_inclusion(:effort, ~w(low medium high xhigh max))
    |> validate_inclusion(:reviewer_effort, ~w(low medium high xhigh max))
    |> validate_number(:max_reviews, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_number(:review_timeout_ms,
      greater_than_or_equal_to: 60_000,
      less_than_or_equal_to: 3_600_000
    )
    |> validate_effort(:kind, :effort)
    |> validate_effort(:reviewer_kind, :reviewer_effort)
    |> unique_constraint(:name)
  end

  defp validate_effort(changeset, kind_field, effort_field) do
    effort = get_field(changeset, effort_field)

    allowed = [nil | efforts(get_field(changeset, kind_field))]

    if effort in allowed,
      do: changeset,
      else: add_error(changeset, effort_field, "is unsupported by this agent")
  end

  def efforts("codex"), do: ~w(low medium high xhigh)
  def efforts("claude"), do: ~w(low medium high max)
  def efforts(_), do: []
end
