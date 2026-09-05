defmodule PtcManager.Repo.Migrations.AllowDirectImplementationApproval do
  use Ecto.Migration

  @moduledoc """
  Lets an approval exist without a proposal, for "Fix directly".

  SQLite cannot drop a NOT NULL constraint in place, so the table is rebuilt.
  Foreign-key enforcement has to be off while that happens — deferring it is not
  enough, because dropping a parent table records a violation per child row that
  recreating the table does not clear — and a pragma only takes effect outside a
  transaction, hence `disable_ddl_transaction`.

  The rebuild itself still runs inside one `BEGIN IMMEDIATE` transaction, so an
  interrupted run rolls back with `approvals` intact instead of leaving the only
  copy of the data in a scratch table. `legacy_alter_table` keeps the rename from
  walking a schema that briefly has no `approvals`, and both pragmas are restored
  even when the rebuild raises. This mirrors
  `20260830073000_import_external_pull_requests`.
  """

  @disable_ddl_transaction true

  def up, do: rebuild(true)
  def down, do: rebuild(false)

  defp rebuild(nullable?) do
    dynamic_repo = PtcManager.Repo.get_dynamic_repo()

    execute(fn ->
      %{adapter: adapter} = meta = Ecto.Adapter.lookup_meta(dynamic_repo)

      adapter.checkout(meta, [], fn -> rebuild_approvals!(dynamic_repo, nullable?) end)
    end)
  end

  defp rebuild_approvals!(repo, nullable?) do
    query!(repo, "PRAGMA foreign_keys = OFF")
    query!(repo, "PRAGMA legacy_alter_table = ON")

    try do
      query!(repo, "BEGIN IMMEDIATE")

      try do
        query!(repo, "ALTER TABLE approvals RENAME TO approvals_rebuild")
        query!(repo, create_approvals(nullable?))

        query!(repo, """
        INSERT INTO approvals
          (id, proposal_id, decision, actor, source_updated_at, source_digest,
           proposal_digest, approved_at, inserted_at)
        SELECT
          id, proposal_id, decision, actor, source_updated_at, source_digest,
          proposal_digest, approved_at, inserted_at
        FROM approvals_rebuild
        """)

        query!(repo, "DROP TABLE approvals_rebuild")

        case query!(repo, "PRAGMA foreign_key_check").rows do
          [] ->
            query!(repo, "COMMIT")

          rows ->
            raise "foreign-key violations after rebuilding approvals: #{inspect(rows)}"
        end
      rescue
        error ->
          _ = Ecto.Adapters.SQL.query(repo, "ROLLBACK", [])
          reraise error, __STACKTRACE__
      end
    after
      query!(repo, "PRAGMA legacy_alter_table = OFF")
      query!(repo, "PRAGMA foreign_keys = ON")
    end
  end

  defp create_approvals(nullable?) do
    required = if nullable?, do: "", else: " NOT NULL"

    """
    CREATE TABLE approvals (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      proposal_id INTEGER#{required} CONSTRAINT approvals_proposal_id_fkey REFERENCES proposals(id) ON DELETE RESTRICT,
      decision TEXT NOT NULL,
      actor TEXT NOT NULL,
      source_updated_at TEXT NOT NULL,
      source_digest TEXT NOT NULL,
      proposal_digest TEXT#{required},
      approved_at TEXT NOT NULL,
      inserted_at TEXT NOT NULL
    )
    """
  end

  defp query!(repo, sql), do: Ecto.Adapters.SQL.query!(repo, sql, [])
end
