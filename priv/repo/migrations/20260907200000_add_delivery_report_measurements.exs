defmodule PtcManager.Repo.Migrations.AddDeliveryReportMeasurements do
  use Ecto.Migration

  def change do
    alter table(:resource_operations) do
      add :resource_metrics, :map
    end

    alter table(:issues) do
      add :github_comment_count, :integer
      add :comments_checked_at, :utc_datetime_usec
    end

    alter table(:pr_publications) do
      add :comment_count, :integer
      add :inline_comment_count, :integer
    end

    alter table(:review_rounds) do
      add :usage, :map
    end
  end
end
