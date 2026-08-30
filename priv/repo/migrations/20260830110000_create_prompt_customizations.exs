defmodule PtcManager.Repo.Migrations.CreatePromptCustomizations do
  use Ecto.Migration

  def change do
    create table(:prompt_customizations) do
      add :action_key, :string, null: false
      add :instructions, :text, null: false
      add :updated_by, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:prompt_customizations, [:action_key])
  end
end
