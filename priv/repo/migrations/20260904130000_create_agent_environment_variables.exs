defmodule PtcManager.Repo.Migrations.CreateAgentEnvironmentVariables do
  use Ecto.Migration

  def change do
    create table(:agent_environment_variables) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :value, :blob, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_environment_variables, [:repository_id, :name])
  end
end
