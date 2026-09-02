defmodule PtcManager.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments) do
      add :repository_id, references(:repositories, on_delete: :restrict), null: false
      add :requested_sha, :string, null: false
      add :previous_sha, :string
      add :state, :string, null: false, default: "queued"
      add :requested_by, :string, null: false
      add :requested_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :release_id, :string
      add :status_text, :text
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:deployments, [:repository_id, :inserted_at])
    create index(:deployments, [:state, :requested_at])

    create unique_index(:deployments, ["(1)"],
             where: "state IN ('queued', 'draining', 'starting', 'running')",
             name: :deployments_one_active
           )
  end
end
