defmodule PtcManager.Repo.Migrations.AddPullRequestHealth do
  use Ecto.Migration

  def change do
    alter table(:pr_publications) do
      add :draft, :boolean, null: false, default: false
      add :mergeability, :string, null: false, default: "unknown"
      add :mergeable_state, :string
      add :checks_state, :string, null: false, default: "unknown"
      add :checks_total, :integer, null: false, default: 0
      add :checks_failed, :integer, null: false, default: 0
      add :checks_pending, :integer, null: false, default: 0
    end
  end
end
