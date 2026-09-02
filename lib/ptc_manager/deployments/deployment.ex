defmodule PtcManager.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued draining starting running completed failed cancelled)
  @terminal_states ~w(completed failed cancelled)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @max_command_bytes PtcManager.Repository.Contract.max_command_bytes()
  @max_timeout_minutes PtcManager.Repository.Contract.max_timeout_minutes()

  @type t :: %__MODULE__{}

  schema "deployments" do
    field :requested_sha, :string
    field :previous_sha, :string
    field :state, :string, default: "queued"
    field :requested_by, :string
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :release_id, :string
    field :status_text, :string
    field :last_error, :string
    field :deployment_command, :string
    field :deployment_timeout_minutes, :integer

    belongs_to :repository, PtcManager.Operations.Repository

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :repository_id,
      :requested_sha,
      :previous_sha,
      :state,
      :requested_by,
      :requested_at,
      :started_at,
      :finished_at,
      :release_id,
      :status_text,
      :last_error,
      :deployment_command,
      :deployment_timeout_minutes
    ])
    |> validate_required([
      :repository_id,
      :requested_sha,
      :state,
      :requested_by,
      :requested_at
    ])
    |> validate_frozen_contract()
    |> validate_inclusion(:state, @states)
    |> validate_format(:requested_sha, @sha)
    |> validate_optional_sha(:previous_sha)
    |> validate_length(:requested_by, max: 160)
    |> validate_length(:release_id, max: 200)
    |> validate_length(:status_text, max: 2_000)
    |> validate_length(:last_error, max: 4_000)
    |> validate_length(:deployment_command, max: @max_command_bytes)
    |> validate_number(:deployment_timeout_minutes,
      greater_than: 0,
      less_than_or_equal_to: @max_timeout_minutes
    )
    |> validate_terminal_time()
    |> unique_constraint(:state, name: :deployments_one_active)
  end

  def terminal_state?(state), do: state in @terminal_states

  defp validate_frozen_contract(changeset) do
    if is_nil(changeset.data.id) or not is_nil(get_field(changeset, :deployment_command)) or
         not is_nil(get_field(changeset, :deployment_timeout_minutes)) do
      validate_required(changeset, [:deployment_command, :deployment_timeout_minutes])
    else
      changeset
    end
  end

  defp validate_optional_sha(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      value when is_binary(value) -> validate_format(changeset, field, @sha)
      _value -> add_error(changeset, field, "must be a Git commit SHA")
    end
  end

  defp validate_terminal_time(changeset) do
    state = get_field(changeset, :state)
    finished_at = get_field(changeset, :finished_at)

    cond do
      terminal_state?(state) and is_nil(finished_at) ->
        add_error(changeset, :finished_at, "is required for a terminal deployment")

      not terminal_state?(state) and not is_nil(finished_at) ->
        add_error(changeset, :finished_at, "is only allowed for a terminal deployment")

      true ->
        changeset
    end
  end
end
