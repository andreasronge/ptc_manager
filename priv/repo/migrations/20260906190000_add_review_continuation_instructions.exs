defmodule PtcManager.Repo.Migrations.AddReviewContinuationInstructions do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :review_continuation_instructions, :text
    end
  end
end
