defmodule PtcManager.RepoTransactionTest do
  use ExUnit.Case, async: true

  alias PtcManager.RepoTransaction

  describe "recognising a busy database" do
    test "the error BEGIN raises when it cannot take the write lock" do
      assert RepoTransaction.busy?(%Exqlite.Error{
               message: "database is locked",
               statement: "BEGIN IMMEDIATE TRANSACTION"
             })
    end

    # This is the one that terminated the operation broker, Oban's cron plugin
    # and the publication reconciler in production. A deferred transaction
    # cannot upgrade to a writer once another connection has committed, so the
    # refusal arrives on the writing statement, spelled differently, and a guard
    # written around `BEGIN IMMEDIATE` never saw it.
    test "the error a writing statement raises when its snapshot is stale" do
      assert RepoTransaction.busy?(%Exqlite.Error{
               message: "Database busy",
               statement: ~S|UPDATE "pr_publications" SET "pr_checked_at" = ?, "updated_at" = ?|
             })

      assert RepoTransaction.busy?(%Exqlite.Error{
               message: "Database busy",
               statement: ~S|INSERT INTO "oban_jobs" ("args","meta") VALUES (?1,?2)|
             })
    end

    test "an unrelated database error is left to its caller" do
      refute RepoTransaction.busy?(%Exqlite.Error{
               message: "no such table: widgets",
               statement: "SELECT 1"
             })

      refute RepoTransaction.busy?(%RuntimeError{message: "database is locked"})
    end
  end
end
