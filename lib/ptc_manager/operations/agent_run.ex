defmodule PtcManager.Operations.AgentRun do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(manager implementer reviewer)
  @states ~w(queued starting working idle blocked waiting unknown done failed lost)
  @terminal_states ~w(done failed lost)

  schema "agent_runs" do
    field :role, :string
    field :state, :string
    field :status_text, :string
    field :agent_name, :string
    field :started_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :state_changed_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :herdr_workspace, :string
    field :herdr_pane, :string
    field :herdr_session, :string
    field :external_key, :string
    field :fencing_token, :integer, default: 0
    field :worker_incarnation_id, :string
    field :herdr_incarnation_id, :string
    field :coordinator_incarnation_id, :string

    belongs_to :worker, PtcManager.Operations.Worker
    belongs_to :job, PtcManager.Operations.Job
    belongs_to :agent_action, PtcManager.Operations.AgentAction
    has_many :resource_operations, PtcManager.Operations.ResourceOperation

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(agent_run, attrs) do
    agent_run
    |> cast(attrs, [
      :worker_id,
      :job_id,
      :agent_action_id,
      :role,
      :state,
      :status_text,
      :agent_name,
      :started_at,
      :last_heartbeat_at,
      :state_changed_at,
      :ended_at,
      :herdr_workspace,
      :herdr_pane,
      :herdr_session,
      :external_key,
      :fencing_token,
      :worker_incarnation_id,
      :herdr_incarnation_id,
      :coordinator_incarnation_id
    ])
    |> validate_required([:worker_id, :role, :state, :started_at, :last_heartbeat_at])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:state, @states)
    |> validate_length(:status_text, max: 240)
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> unique_constraint([:job_id, :fencing_token], name: :agent_runs_one_per_job_attempt)
    |> stamp_state_change()
    |> validate_terminal_time()
  end

  # Every writer records when the run entered its current state, so a caller
  # never has to remember to. A Herdr snapshot rewrites the same state every
  # few seconds; only a real transition moves this stamp.
  defp stamp_state_change(changeset) do
    cond do
      get_change(changeset, :state_changed_at) -> changeset
      is_nil(get_field(changeset, :state_changed_at)) -> put_state_change(changeset)
      get_change(changeset, :state) -> put_state_change(changeset)
      true -> changeset
    end
  end

  defp put_state_change(changeset),
    do: put_change(changeset, :state_changed_at, DateTime.utc_now())

  defp validate_terminal_time(changeset) do
    state = get_field(changeset, :state)
    started_at = get_field(changeset, :started_at)
    ended_at = get_field(changeset, :ended_at)

    cond do
      state in @terminal_states and is_nil(ended_at) ->
        add_error(changeset, :ended_at, "is required when the run has ended")

      state not in @terminal_states and not is_nil(ended_at) ->
        add_error(changeset, :ended_at, "is only allowed when the run has ended")

      started_at && ended_at && DateTime.compare(ended_at, started_at) == :lt ->
        add_error(changeset, :ended_at, "cannot be before the start time")

      true ->
        changeset
    end
  end
end
