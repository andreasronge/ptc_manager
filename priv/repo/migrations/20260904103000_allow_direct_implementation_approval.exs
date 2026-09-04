defmodule PtcManager.Repo.Migrations.AllowDirectImplementationApproval do
  use Ecto.Migration

  @moduledoc """
  Lets an approval exist without a proposal, for "Fix directly".

  SQLite cannot drop a NOT NULL constraint in place, so the table is rebuilt and
  renamed over the old one. Foreign-key enforcement has to be off while that
  happens — deferring it is not enough, because dropping a parent table records
  a violation per child row that recreating the table does not clear — and a
  pragma only takes effect outside a transaction, hence `disable_ddl_transaction`.
  `legacy_alter_table` then keeps the rename from walking a schema that briefly
  has no `approvals` table.
  """

  @disable_ddl_transaction true

  def up, do: rebuild_approvals(nullable?: true)
  def down, do: rebuild_approvals(nullable?: false)

  defp rebuild_approvals(nullable?: nullable?) do
    execute("PRAGMA foreign_keys = OFF")
    # Without a transaction, an interrupted run can leave the scratch table.
    execute("DROP TABLE IF EXISTS approvals_rebuild")

    create table(:approvals_rebuild) do
      add :proposal_id, references(:proposals, on_delete: :restrict), null: nullable?
      add :decision, :string, null: false
      add :actor, :string, null: false
      add :source_updated_at, :utc_datetime_usec, null: false
      add :source_digest, :string, null: false
      add :proposal_digest, :string, null: nullable?
      add :approved_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    execute("""
    INSERT INTO approvals_rebuild
      (id, proposal_id, decision, actor, source_updated_at, source_digest,
       proposal_digest, approved_at, inserted_at)
    SELECT
      id, proposal_id, decision, actor, source_updated_at, source_digest,
      proposal_digest, approved_at, inserted_at
    FROM approvals
    """)

    execute("DROP TABLE approvals")
    execute("PRAGMA legacy_alter_table = ON")
    execute("ALTER TABLE approvals_rebuild RENAME TO approvals")
    execute("PRAGMA legacy_alter_table = OFF")
    execute("PRAGMA foreign_keys = ON")
  end
end
