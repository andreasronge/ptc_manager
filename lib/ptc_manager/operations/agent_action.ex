defmodule PtcManager.Operations.AgentAction do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued running sync_pending done failed)
  @target_types ~w(repository issue pull_request daily_digest)

  schema "agent_actions" do
    field :action_key, :string
    field :target_type, :string
    field :target_id, :integer
    field :target_label, :string
    field :prompt_version, :integer, default: 1
    field :prompt, :string
    field :baseline_issue_numbers, :map, default: %{"numbers" => []}
    field :target_snapshot, :map, default: %{}
    field :actor, :string
    field :state, :string, default: "queued"
    field :attempt_count, :integer, default: 0
    field :attempt_token, :string
    field :attempt_expires_at, :utc_datetime_usec
    field :sync_attempt_count, :integer, default: 0
    field :next_sync_attempt_at, :utc_datetime_usec
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :result_summary, :string
    field :last_error, :string

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :automation_definition_version, PtcManager.Automations.DefinitionVersion
    has_many :agent_runs, PtcManager.Operations.AgentRun

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :repository_id,
      :automation_definition_version_id,
      :action_key,
      :target_type,
      :target_id,
      :target_label,
      :prompt_version,
      :prompt,
      :baseline_issue_numbers,
      :target_snapshot,
      :actor,
      :state,
      :attempt_count,
      :attempt_token,
      :attempt_expires_at,
      :sync_attempt_count,
      :next_sync_attempt_at,
      :requested_at,
      :started_at,
      :ended_at,
      :result_summary,
      :last_error
    ])
    |> validate_required([
      :repository_id,
      :action_key,
      :target_type,
      :target_id,
      :target_label,
      :prompt_version,
      :prompt,
      :baseline_issue_numbers,
      :target_snapshot,
      :actor,
      :state,
      :attempt_count,
      :requested_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:target_type, @target_types)
    |> validate_number(:target_id, greater_than: 0)
    |> validate_number(:prompt_version, greater_than: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:sync_attempt_count, greater_than_or_equal_to: 0)
    |> validate_length(:action_key, max: 80)
    |> validate_length(:target_label, max: 240)
    |> validate_length(:actor, max: 120)
    |> validate_length(:attempt_token, max: 64)
    |> validate_length(:last_error, max: 1_000)
    |> unique_constraint(:action_key, name: :agent_actions_one_active_per_target)
    |> unique_constraint(:action_key, name: :agent_actions_target_type_target_id_index)
    |> unique_constraint(:action_key,
      name: :agent_actions_one_active_repository_action
    )
    |> unique_constraint(:action_key,
      name: :agent_actions_action_key_target_type_target_id_index
    )
  end
end
