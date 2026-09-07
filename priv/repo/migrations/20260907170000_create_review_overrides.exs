defmodule PtcManager.Repo.Migrations.CreateReviewOverrides do
  use Ecto.Migration

  def change do
    create table(:review_overrides) do
      add :job_id, references(:jobs, on_delete: :delete_all), null: false
      add :round_id, references(:review_rounds, on_delete: :delete_all), null: false
      add :fencing_token, :integer, null: false
      add :generation, :integer, null: false
      add :head_sha, :string, null: false
      add :base_sha, :string, null: false
      add :diff_digest, :string, null: false
      add :actor, :string, null: false
      add :reason, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:review_overrides, [:job_id, :generation])
  end
end
