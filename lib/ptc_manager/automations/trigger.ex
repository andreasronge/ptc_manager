defmodule PtcManager.Automations.Trigger do
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(manual schedule contextual)
  @surfaces ~w(automations planning_issue delivery_pr)

  schema "automation_triggers" do
    field :trigger_type, :string
    field :surface, :string
    field :label, :string
    field :enabled, :boolean, default: true
    field :configuration, :map, default: %{}
    field :cron_expression, :string
    field :time_zone, :string
    field :next_run_at, :utc_datetime_usec
    field :last_enqueued_at, :utc_datetime_usec

    belongs_to :automation_definition, PtcManager.Automations.Definition
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :automation_definition_id,
      :trigger_type,
      :surface,
      :label,
      :enabled,
      :configuration,
      :cron_expression,
      :time_zone,
      :next_run_at,
      :last_enqueued_at
    ])
    |> validate_required([
      :automation_definition_id,
      :trigger_type,
      :surface,
      :label,
      :enabled,
      :configuration
    ])
    |> validate_inclusion(:trigger_type, @types)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_length(:label, max: 120)
    |> validate_schedule()
    |> unique_constraint([:automation_definition_id, :trigger_type, :surface])
  end

  defp validate_schedule(changeset) do
    if get_field(changeset, :trigger_type) == "schedule" do
      validate_required(changeset, [:cron_expression, :time_zone])
    else
      changeset
    end
  end
end
