defmodule PtcManager.Repo.Migrations.CreateManagerTables do
  use Ecto.Migration

  def change do
    create table(:repositories) do
      add :github_owner, :string, null: false
      add :github_name, :string, null: false
      add :default_branch, :string, null: false, default: "main"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:repositories, [:github_owner, :github_name])

    create table(:issues) do
      add :repository_id, references(:repositories, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :title, :string, null: false
      add :html_url, :string, null: false
      add :state, :string, null: false, default: "open"
      add :body_digest, :string, null: false
      add :content_digest, :string, null: false
      add :github_updated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issues, [:repository_id, :number])

    create table(:proposals) do
      add :issue_id, references(:issues, on_delete: :delete_all), null: false
      add :source_updated_at, :utc_datetime_usec, null: false
      add :source_digest, :string, null: false
      add :proposal_digest, :string, null: false
      add :plain_summary, :text, null: false
      add :why_it_matters, :text, null: false
      add :scope, :string, null: false
      add :risk, :string, null: false
      add :readiness, :string, null: false
      add :technical_evidence, :text, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:proposals, [:issue_id, :inserted_at])

    create table(:approvals) do
      add :proposal_id, references(:proposals, on_delete: :restrict), null: false
      add :decision, :string, null: false
      add :actor, :string, null: false
      add :source_updated_at, :utc_datetime_usec, null: false
      add :source_digest, :string, null: false
      add :proposal_digest, :string, null: false
      add :approved_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:jobs) do
      add :repository_id, references(:repositories, on_delete: :restrict), null: false
      add :issue_id, references(:issues, on_delete: :restrict), null: false
      add :approval_id, references(:approvals, on_delete: :restrict), null: false
      add :kind, :string, null: false, default: "implementation"
      add :state, :string, null: false, default: "queued"
      add :fencing_token, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:jobs, [:issue_id],
             where: "state IN ('queued', 'starting', 'working', 'idle', 'blocked')",
             name: :jobs_one_active_per_issue
           )

    create table(:workers) do
      add :worker_key, :string, null: false
      add :name, :string, null: false
      add :status, :string, null: false, default: "offline"
      add :capabilities, :map, null: false, default: %{}
      add :last_heartbeat_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workers, [:worker_key])

    create table(:agent_runs) do
      add :worker_id, references(:workers, on_delete: :restrict), null: false
      add :job_id, references(:jobs, on_delete: :nilify_all)
      add :role, :string, null: false
      add :state, :string, null: false
      add :status_text, :string
      add :started_at, :utc_datetime_usec, null: false
      add :last_heartbeat_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :herdr_workspace, :string
      add :herdr_pane, :string
      add :herdr_session, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_runs, [:worker_id, :state])
    create index(:agent_runs, [:job_id])

    create table(:audit_events) do
      add :actor, :string, null: false
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :integer, null: false
      add :details, :map, null: false, default: %{}

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:audit_events, [:target_type, :target_id, :inserted_at])
  end
end
