defmodule PtcManager.Repo.Migrations.AddExecutionProfilesAndReviews do
  use Ecto.Migration

  def change do
    create table(:execution_profiles) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :model, :string, null: false
      add :effort, :string
      add :reviewer_kind, :string, null: false
      add :reviewer_model, :string, null: false
      add :reviewer_effort, :string
      add :max_reviews, :integer, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:execution_profiles, [:name])

    for {name, model, budget} <- [
          {"small", "gpt-5.4-mini", 1},
          {"standard", "gpt-5.6-sol", 2},
          {"strong", "gpt-6-astra", 5}
        ] do
      execute(
        "INSERT INTO execution_profiles (name, kind, model, reviewer_kind, reviewer_model, max_reviews, inserted_at, updated_at) VALUES ('#{name}', 'codex', '#{model}', 'codex', 'gpt-6-astra', #{budget}, strftime('%Y-%m-%dT%H:%M:%fZ','now'), strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
        "DELETE FROM execution_profiles WHERE name = '#{name}'"
      )
    end

    alter table(:jobs) do
      add :execution_settings, :map
      add :review_state, :string
      add :reviewed_head_sha, :string
      add :review_generation, :integer, null: false, default: 0
    end

    create table(:review_rounds) do
      add :job_id, references(:jobs, on_delete: :restrict), null: false
      add :fencing_token, :integer, null: false
      add :generation, :integer, null: false
      add :number, :integer, null: false
      add :request_id, :string, null: false
      add :state, :string, null: false
      add :head_sha, :string, null: false
      add :base_sha, :string, null: false
      add :diff_digest, :string, null: false
      add :input, :map, null: false
      add :result, :map
      add :error, :string
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:review_rounds, [:job_id, :number])
    create unique_index(:review_rounds, [:job_id, :request_id])

    create unique_index(:review_rounds, [:job_id],
             name: :one_running_review,
             where: "state IN ('queued', 'running')"
           )
  end
end
