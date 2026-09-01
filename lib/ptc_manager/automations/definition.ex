defmodule PtcManager.Automations.Definition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "automation_definitions" do
    field :key, :string
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :archived_at, :utc_datetime_usec

    belongs_to :repository, PtcManager.Operations.Repository
    belongs_to :current_version, PtcManager.Automations.DefinitionVersion

    has_many :versions, PtcManager.Automations.DefinitionVersion,
      foreign_key: :automation_definition_id

    has_many :triggers, PtcManager.Automations.Trigger, foreign_key: :automation_definition_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :repository_id,
      :key,
      :name,
      :description,
      :enabled,
      :archived_at,
      :current_version_id
    ])
    |> validate_required([:repository_id, :key, :name, :description, :enabled])
    |> update_change(:key, &String.trim/1)
    |> validate_format(:key, ~r/\A[a-z][a-z0-9_]*\z/)
    |> validate_length(:key, max: 80)
    |> validate_length(:name, max: 160)
    |> validate_length(:description, max: 2_000)
    |> unique_constraint([:repository_id, :key])
    |> foreign_key_constraint(:current_version_id)
  end
end
