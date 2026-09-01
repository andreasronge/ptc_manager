defmodule PtcManager.Automations.Invocation do
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued running synchronizing succeeded no_changes blocked failed cancelled)
  @trigger_types ~w(manual schedule contextual)

  schema "automation_invocations" do
    field :trigger_type, :string
    field :trigger_context, :map, default: %{}
    field :occurrence_key, :string
    field :state, :string, default: "queued"
    field :source_sha, :string
    field :selected_agent_kind, :string
    field :selected_agent_name, :string
    field :result_status, :string
    field :result_markdown, :string
    field :requested_by, :string
    field :requested_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :last_error, :string

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :automation_definition_version, PtcManager.Automations.DefinitionVersion
    belongs_to :automation_trigger, PtcManager.Automations.Trigger
    belongs_to :agent_action, PtcManager.Operations.AgentAction
    belongs_to :job, PtcManager.Operations.Job

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(invocation, attrs) do
    invocation
    |> cast(attrs, [
      :repository_id,
      :automation_definition_version_id,
      :automation_trigger_id,
      :agent_action_id,
      :job_id,
      :trigger_type,
      :trigger_context,
      :occurrence_key,
      :state,
      :source_sha,
      :selected_agent_kind,
      :selected_agent_name,
      :result_status,
      :result_markdown,
      :requested_by,
      :requested_at,
      :started_at,
      :ended_at,
      :last_error
    ])
    |> validate_required([
      :repository_id,
      :automation_definition_version_id,
      :trigger_type,
      :trigger_context,
      :state,
      :requested_by,
      :requested_at
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:trigger_type, @trigger_types)
    |> validate_length(:selected_agent_kind, max: 80)
    |> validate_length(:selected_agent_name, max: 160)
    |> validate_length(:last_error, max: 2_000)
    |> unique_constraint([:automation_trigger_id, :occurrence_key])
  end
end
