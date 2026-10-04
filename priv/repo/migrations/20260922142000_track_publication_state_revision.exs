defmodule PtcManager.Repo.Migrations.TrackPublicationStateRevision do
  use Ecto.Migration

  @table "pr_publications"

  def up do
    Enum.each(~w(insert update delete), fn operation ->
      execute("""
      CREATE TRIGGER #{trigger_name(operation)}
      AFTER #{String.upcase(operation)} ON #{@table}
      BEGIN
        UPDATE herdr_state_revisions SET revision = revision + 1 WHERE id = 1;
      END
      """)
    end)
  end

  def down do
    Enum.each(~w(insert update delete), fn operation ->
      execute("DROP TRIGGER IF EXISTS #{trigger_name(operation)}")
    end)
  end

  defp trigger_name(operation), do: "#{@table}_herdr_revision_after_#{operation}"
end
