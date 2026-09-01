defmodule PtcManager.Operations.ResourceOperation do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued starting running cancelling recovery_pending completed failed cancelled lost)
  @terminal_states ~w(completed failed cancelled lost)
  @label ~r/\A[a-z][a-z0-9_-]{0,39}\z/

  schema "resource_operations" do
    field :invocation_id, :string
    field :label, :string
    field :priority, :integer, default: 0
    field :state, :string, default: "queued"
    field :slot_number, :integer
    field :fencing_token, :integer, default: 0
    field :attempt_token, :string
    field :wrapper_pid, :integer
    field :cgroup_path, :string
    field :queued_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :wait_duration_ms, :integer
    field :run_duration_ms, :integer
    field :exit_status, :integer
    field :peak_memory_bytes, :integer
    field :cancellation_reason, :string
    field :last_error, :string

    belongs_to :worker, PtcManager.Operations.Worker
    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :job, PtcManager.Operations.Job
    belongs_to :agent_action, PtcManager.Operations.AgentAction
    belongs_to :agent_run, PtcManager.Operations.AgentRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :worker_id,
      :repository_id,
      :job_id,
      :agent_action_id,
      :agent_run_id,
      :invocation_id,
      :label,
      :priority,
      :state,
      :slot_number,
      :fencing_token,
      :attempt_token,
      :wrapper_pid,
      :cgroup_path,
      :queued_at,
      :started_at,
      :last_heartbeat_at,
      :finished_at,
      :wait_duration_ms,
      :run_duration_ms,
      :exit_status,
      :peak_memory_bytes,
      :cancellation_reason,
      :last_error
    ])
    |> validate_required([
      :worker_id,
      :repository_id,
      :agent_run_id,
      :invocation_id,
      :label,
      :priority,
      :state,
      :queued_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_format(:label, @label)
    |> validate_length(:invocation_id, max: 120)
    |> validate_length(:attempt_token, max: 120)
    |> validate_length(:cgroup_path, max: 1_024)
    |> validate_length(:cancellation_reason, max: 500)
    |> validate_length(:last_error, max: 1_000)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000)
    |> validate_number(:slot_number, greater_than: 0, less_than_or_equal_to: 64)
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> validate_number(:wrapper_pid, greater_than: 0)
    |> validate_number(:wait_duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:run_duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:exit_status, greater_than_or_equal_to: 0, less_than_or_equal_to: 255)
    |> validate_number(:peak_memory_bytes, greater_than_or_equal_to: 0)
    |> validate_exactly_one_owner()
    |> validate_terminal_fields()
    |> unique_constraint(:invocation_id)
    |> unique_constraint([:worker_id, :slot_number],
      name: :resource_operations_one_active_owner_per_slot
    )
  end

  def terminal_state?(state), do: state in @terminal_states

  defp validate_exactly_one_owner(changeset) do
    case {get_field(changeset, :job_id), get_field(changeset, :agent_action_id)} do
      {job_id, nil} when is_integer(job_id) -> changeset
      {nil, action_id} when is_integer(action_id) -> changeset
      _other -> add_error(changeset, :job_id, "must identify exactly one owning job or action")
    end
  end

  defp validate_terminal_fields(changeset) do
    state = get_field(changeset, :state)
    finished_at = get_field(changeset, :finished_at)

    cond do
      terminal_state?(state) and is_nil(finished_at) ->
        add_error(changeset, :finished_at, "is required for a terminal operation")

      not terminal_state?(state) and not is_nil(finished_at) ->
        add_error(changeset, :finished_at, "is only allowed for a terminal operation")

      true ->
        changeset
    end
  end
end
