defmodule PtcManager.Repo.Migrations.RecordRepositoryGithubLabels do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :github_label_names, :map, default: %{"names" => []}
      add :github_labels_checked_at, :utc_datetime_usec
    end
  end
end
