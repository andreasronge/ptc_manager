defmodule PtcManager.Repo.Migrations.AddHerdrStateRevision do
  use Ecto.Migration

  @tracked_tables ~w(workers agent_runs jobs worktree_allocations agent_actions)

  def up do
    create table(:herdr_state_revisions, primary_key: false) do
      add :id, :integer, primary_key: true
      add :revision, :integer, null: false, default: 0
    end

    execute("INSERT INTO herdr_state_revisions (id, revision) VALUES (1, 0)")

    Enum.each(@tracked_tables, fn table ->
      Enum.each(~w(insert update delete), fn operation ->
        execute("""
        CREATE TRIGGER #{trigger_name(table, operation)}
        AFTER #{String.upcase(operation)} ON #{table}
        BEGIN
          UPDATE herdr_state_revisions SET revision = revision + 1 WHERE id = 1;
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

    drop table(:herdr_state_revisions)
  end

  defp trigger_name(table, operation), do: "#{table}_herdr_revision_after_#{operation}"
end
