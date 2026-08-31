defmodule PtcManager.PromptConfiguration.Customization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "prompt_customizations" do
    field :action_key, :string
    field :instructions, :string
    field :updated_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(customization, attrs) do
    customization
    |> cast(attrs, [:action_key, :instructions, :updated_by])
    |> update_change(:action_key, &String.trim/1)
    |> update_change(:instructions, &String.trim/1)
    |> validate_required([:action_key, :instructions, :updated_by])
    |> validate_length(:instructions, max: 20_000)
    |> validate_change(:instructions, fn :instructions, instructions ->
      if byte_size(instructions) <= 20_000,
        do: [],
        else: [instructions: "must be at most 20000 bytes"]
    end)
    |> unique_constraint(:action_key)
  end
end
