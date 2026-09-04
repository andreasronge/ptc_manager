defmodule PtcManager.Repo.Migrations.AddPullRequestFollowUpSignal do
  use Ecto.Migration

  def change do
    alter table(:pr_publications) do
      add :labels, :map, default: %{"names" => []}
      add :follow_up_dismissed_at, :utc_datetime_usec
    end
  end
end
