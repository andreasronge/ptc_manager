defmodule PtcManager.Repo.Migrations.AddUxExecutionProfile do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :execution_profile_mappings, :map, null: false, default: %{"mappings" => []}
    end

    execute(
      """
      INSERT INTO execution_profiles
        (name, kind, model, effort, reviewer_kind, reviewer_model, max_reviews,
         review_timeout_ms, inserted_at, updated_at)
      VALUES ('ux', 'claude', 'claude-opus-5-5', 'high', 'codex', 'gpt-6.1-sol', 2,
              900000, strftime('%Y-%m-%dT%H:%M:%fZ','now'), strftime('%Y-%m-%dT%H:%M:%fZ','now'))
      """,
      "DELETE FROM execution_profiles WHERE name = 'ux'"
    )
  end
end
