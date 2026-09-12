defmodule PtcManager.RepoTransactionTest do
  use ExUnit.Case, async: true

  alias PtcManager.{Repo, RepoTransaction}

  describe "taking the write lock up front" do
    # Two connections on one database, outside the sandbox. The first reads
    # inside a transaction, the second commits a write, then the first writes.
    # A deferred transaction is refused at that point; an immediate one already
    # holds the lock, so the second writer waits for it instead.
    test "a transaction that reads and then writes survives a concurrent commit" do
      database =
        Path.join(
          System.tmp_dir!(),
          "ptc-manager-immediate-#{System.unique_integer([:positive])}.db"
        )

      {:ok, repo} =
        Repo.start_link(
          name: nil,
          database: database,
          pool_size: 3,
          pool: DBConnection.ConnectionPool,
          busy_timeout: 2_000
        )

      Process.unlink(repo)

      on_exit(fn ->
        if Process.alive?(repo), do: Supervisor.stop(repo)
        for suffix <- ["", "-shm", "-wal"], do: File.rm(database <> suffix)
      end)

      Repo.put_dynamic_repo(repo)
      Repo.query!("CREATE TABLE counters (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
      test_pid = self()

      reader_writer =
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.transaction(fn ->
            %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM counters")
            send(test_pid, :read_done)

            receive do
              :write -> Repo.query!("INSERT INTO counters (n) VALUES (1)")
            end

            :written
          end)
        end)

      assert_receive :read_done

      concurrent_writer =
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          Repo.query!("INSERT INTO counters (n) VALUES (2)")
          :committed
        end)

      refute_receive {_ref, :committed}, 200
      send(reader_writer.pid, :write)

      assert {:ok, :written} = Task.await(reader_writer)
      assert :committed = Task.await(concurrent_writer)
      assert %{rows: [[2]]} = Repo.query!("SELECT count(*) FROM counters")
    end
  end

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
