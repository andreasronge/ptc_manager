defmodule PtcManager.Repo.Migrations.TrackGithubSyncStateRevision do
  use Ecto.Migration

  @tracked_tables ~w(repositories issues issue_dependencies)

  def up do
    create table(:github_sync_state_revisions, primary_key: false) do
      add :id, :integer, primary_key: true
      add :revision, :integer, null: false, default: 0
    end

    execute("INSERT INTO github_sync_state_revisions (id, revision) VALUES (1, 0)")

    Enum.each(@tracked_tables, fn table ->
      Enum.each(~w(insert update delete), fn operation ->
        execute("""
        CREATE TRIGGER #{trigger_name(table, operation)}
        AFTER #{String.upcase(operation)} ON #{table}
        BEGIN
          UPDATE github_sync_state_revisions SET revision = revision + 1 WHERE id = 1;
        END
        """)
      end)
    end)
  end

  def down do
    Enum.each(@tracked_tables, fn table ->
      Enum.each(~w(insert update delete), fn operation ->
        execute("DROP TRIGGER IF EXISTS #{trigger_name(table, operation)}")
      end)
    end)

    drop table(:github_sync_state_revisions)
  end

  defp trigger_name(table, operation), do: "#{table}_github_sync_revision_after_#{operation}"
end
