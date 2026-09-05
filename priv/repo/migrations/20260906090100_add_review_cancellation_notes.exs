defmodule PtcManager.Repo.Migrations.AddReviewCancellationNotes do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :review_resume_expires_at, :utc_datetime_usec
      add :cancellation_reason, :text
      add :cancellation_action_id, references(:agent_actions, on_delete: :restrict)
    end
  end
end
