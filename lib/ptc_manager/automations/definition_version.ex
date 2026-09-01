defmodule PtcManager.Automations.DefinitionVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @target_types ~w(repository issue pull_request)
  @profiles ~w(generic_ephemeral retained_pr_repair implementation_job private_daily_update)
  @github_access ~w(none read trusted_direct brokered_publish)
  @queue_lanes ~w(planning writing)
  @resource_classes ~w(light heavy)

  schema "automation_definition_versions" do
    field :version, :integer
    field :target_type, :string
    field :execution_profile, :string
    field :agent_selector, :map, default: %{}
    field :github_access, :string
    field :queue_lane, :string
    field :resource_class, :string
    field :lock_policy, :map, default: %{}
    field :timeout_seconds, :integer
    field :result_type, :string
    field :result_protocol_version, :integer, default: 1
    field :prompt, :string, default: ""
    field :configuration_snapshot, :map, default: %{}
    field :created_by, :string

    belongs_to :automation_definition, PtcManager.Automations.Definition

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :automation_definition_id,
      :version,
      :target_type,
      :execution_profile,
      :agent_selector,
      :github_access,
      :queue_lane,
      :resource_class,
      :lock_policy,
      :timeout_seconds,
      :result_type,
      :result_protocol_version,
      :prompt,
      :configuration_snapshot,
      :created_by
    ])
    |> validate_required([
      :automation_definition_id,
      :version,
      :target_type,
      :execution_profile,
      :agent_selector,
      :github_access,
      :queue_lane,
      :resource_class,
      :lock_policy,
      :timeout_seconds,
      :result_type,
      :result_protocol_version,
      :prompt,
      :configuration_snapshot,
      :created_by
    ])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:execution_profile, @profiles)
    |> validate_inclusion(:github_access, @github_access)
    |> validate_inclusion(:queue_lane, @queue_lanes)
    |> validate_inclusion(:resource_class, @resource_classes)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:timeout_seconds, greater_than: 0, less_than_or_equal_to: 86_400)
    |> validate_number(:result_protocol_version, greater_than: 0)
    |> validate_length(:result_type, max: 100)
    |> validate_length(:created_by, max: 120)
    |> unique_constraint([:automation_definition_id, :version])
  end
end
