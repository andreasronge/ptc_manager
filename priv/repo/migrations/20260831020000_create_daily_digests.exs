defmodule PtcManager.Repo.Migrations.CreateDailyDigests do
  use Ecto.Migration

  def change do
    create table(:daily_digests) do
      add :repository_id, references(:repositories, on_delete: :restrict), null: false
      add :agent_action_id, references(:agent_actions, on_delete: :nilify_all)
      add :digest_date, :date, null: false
      add :window_started_at, :utc_datetime_usec, null: false
      add :window_ended_at, :utc_datetime_usec, null: false
      add :time_zone, :string, null: false
      add :title, :string
      add :summary, :text
      add :markdown, :text
      add :source_head_sha, :string
      add :change_count, :integer, null: false, default: 0
      add :pull_request_numbers, :map, null: false, default: %{"numbers" => []}
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:daily_digests, [:repository_id, :digest_date])
    create unique_index(:daily_digests, [:agent_action_id])
    create index(:daily_digests, [:digest_date, :id])
  end
end
