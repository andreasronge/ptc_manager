defmodule PtcManager.Repo.Migrations.AddReviewTimeoutToExecutionProfiles do
  use Ecto.Migration

  def change do
    alter table(:execution_profiles) do
      add :review_timeout_ms, :integer, null: false, default: 900_000
    end
  end
end
