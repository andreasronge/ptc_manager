defmodule PtcManager.Operations.AgentRun do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(manager implementer reviewer)
  @states ~w(queued starting working idle blocked waiting unknown done failed lost)
  @terminal_states ~w(done failed lost)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  schema "agent_runs" do
    field :role, :string
    field :state, :string
    field :status_text, :string
    field :agent_name, :string
    field :started_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :herdr_workspace, :string
    field :herdr_pane, :string
    field :herdr_session, :string
    field :external_key, :string
    field :fencing_token, :integer, default: 0
    field :worker_incarnation_id, :string
    field :herdr_incarnation_id, :string
    field :coordinator_incarnation_id, :string
    field :disposable_worktree_path, :string
    field :disposable_worktree_branch, :string
    field :disposable_cleanup_state, :string
    field :disposable_cleanup_token, :string
    field :disposable_cleanup_expires_at, :utc_datetime_usec
    field :workspace_setup_state, :string
    field :workspace_setup_script, :string
    field :workspace_setup_source_sha, :string
    field :workspace_setup_started_at, :utc_datetime_usec
    field :workspace_setup_ended_at, :utc_datetime_usec
    field :workspace_setup_duration_ms, :integer
    field :workspace_setup_exit_status, :integer
    field :workspace_setup_output, :string
    field :workspace_setup_output_truncated, :boolean, default: false
    field :workspace_setup_cache_state, :string
    field :workspace_setup_phase_durations, :map, default: %{}
    field :workspace_setup_error, :string

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
      :ended_at,
      :herdr_workspace,
      :herdr_pane,
      :herdr_session,
      :external_key,
      :fencing_token,
      :worker_incarnation_id,
      :herdr_incarnation_id,
      :coordinator_incarnation_id,
      :disposable_worktree_path,
      :disposable_worktree_branch,
      :disposable_cleanup_state,
      :disposable_cleanup_token,
      :disposable_cleanup_expires_at,
      :workspace_setup_state,
      :workspace_setup_script,
      :workspace_setup_source_sha,
      :workspace_setup_started_at,
      :workspace_setup_ended_at,
      :workspace_setup_duration_ms,
      :workspace_setup_exit_status,
      :workspace_setup_output,
      :workspace_setup_output_truncated,
      :workspace_setup_cache_state,
      :workspace_setup_phase_durations,
      :workspace_setup_error
    ])
    |> validate_required([:worker_id, :role, :state, :started_at, :last_heartbeat_at])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:state, @states)
    |> validate_length(:status_text, max: 240)
    |> validate_length(:disposable_worktree_path, max: 1_000)
    |> validate_length(:disposable_worktree_branch, max: 240)
    |> validate_inclusion(:workspace_setup_state, ["passed", "failed"], allow_nil: true)
    |> validate_inclusion(:workspace_setup_cache_state, ["hit", "miss", "disabled"],
      allow_nil: true
    )
    |> validate_number(:workspace_setup_duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:workspace_setup_exit_status, greater_than_or_equal_to: 0)
    |> validate_length(:workspace_setup_script, max: 2_000)
    |> validate_length(:workspace_setup_output, max: 65_536)
    |> validate_length(:workspace_setup_error, max: 500)
    |> validate_format(:workspace_setup_source_sha, @sha)
    |> validate_inclusion(
      :disposable_cleanup_state,
      ["planned", "workspace_open", "branch_pending"],
      allow_nil: true
    )
    |> validate_number(:fencing_token, greater_than_or_equal_to: 0)
    |> unique_constraint([:job_id, :fencing_token], name: :agent_runs_one_per_job_attempt)
    |> validate_terminal_time()
  end

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
