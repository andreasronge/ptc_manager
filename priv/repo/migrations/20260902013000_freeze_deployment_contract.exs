defmodule PtcManager.Repo.Migrations.FreezeDeploymentContract do
  use Ecto.Migration

  def up do
    alter table(:deployments) do
      add :deployment_command, :string
      add :deployment_timeout_minutes, :integer
    end
  end

  def down do
    alter table(:deployments) do
      remove :deployment_command
      remove :deployment_timeout_minutes
    end
  end
end
