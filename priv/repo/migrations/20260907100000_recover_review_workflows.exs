defmodule PtcManager.Repo.Migrations.RecoverReviewWorkflows do
  use Ecto.Migration

  def up do
    # No tables reference review_rounds. Rebuild it atomically to admit failures
    # before a SHA exists; SQLite does not support altering column nullability.
    create table(:review_rounds_next) do
      add :job_id, references(:jobs, on_delete: :restrict), null: false
      for column <- [:fencing_token, :generation, :number], do: add(column, :integer, null: false)
      for column <- [:request_id, :state], do: add(column, :string, null: false)
      for column <- [:head_sha, :base_sha, :diff_digest, :error], do: add(column, :string)
      add :input, :map, null: false
      add :result, :map
      add :failure, :map
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    INSERT INTO review_rounds_next (id, job_id, fencing_token, generation, number, request_id,
      state, head_sha, base_sha, diff_digest, input, result, error, expires_at, inserted_at, updated_at)
    SELECT id, job_id, fencing_token, generation, number, request_id, state, head_sha, base_sha,
      diff_digest, input, result, error, expires_at, inserted_at, updated_at FROM review_rounds
    """)

    drop table(:review_rounds)
    rename table(:review_rounds_next), to: table(:review_rounds)
    create unique_index(:review_rounds, [:job_id, :number])
    create unique_index(:review_rounds, [:job_id, :request_id])

    create unique_index(:review_rounds, [:job_id],
             name: :one_running_review,
             where: "state IN ('preparing', 'queued', 'running')"
           )

    alter table(:jobs) do
      add :review_resume_mode, :string
      add :review_recovery_expires_at, :utc_datetime_usec
    end
  end

  def down, do: raise("Review setup failures cannot be represented by the previous schema")
end
