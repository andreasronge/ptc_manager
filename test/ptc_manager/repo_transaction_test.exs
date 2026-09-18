defmodule PtcManager.RepoTransactionTest do
  use ExUnit.Case, async: true

  alias PtcManager.{Repo, RepoTransaction}

  describe "taking the write lock up front" do
    # Two connections on one database, outside the sandbox. The first reads
    # inside a transaction, the second commits a write, then the first writes.
    # A deferred transaction is refused at that point; an immediate one already
    # holds the lock, so the second writer waits for it instead.
    test "a transaction that reads and then writes survives a concurrent commit" do
      repo = start_repo!(pool_size: 3, busy_timeout: 2_000)

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

    test "a writer burst larger than the pool waits for the current writer" do
      repo =
        start_repo!(
          pool_size: 2,
          busy_timeout: 300,
          queue_target: 100,
          queue_interval: 20,
          timeout: 800
        )

      Repo.put_dynamic_repo(repo)
      Repo.query!("CREATE TABLE counters (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)")
      test_pid = self()

      holder =
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)

          Repo.transaction(fn ->
            Repo.query!("INSERT INTO counters (n) VALUES (1)")
            send(test_pid, :writer_lock_held)

            receive do
              :release_writer -> :ok
            end
          end)
        end)

      assert_receive :writer_lock_held

      queued_writers =
        for value <- [2, 3] do
          Task.async(fn ->
            Repo.put_dynamic_repo(repo)
            Repo.query!("INSERT INTO counters (n) VALUES (?)", [value])
          end)
        end

      {DBConnection.ConnectionPool, pool, :worker, _modules} =
        Enum.find(Supervisor.which_children(repo), fn {id, _pid, _type, _modules} ->
          id == DBConnection.ConnectionPool
        end)

      await_checkout_queue(pool, 1)
      Process.sleep(150)
      refute Enum.any?(queued_writers, &match?({:ok, _}, Task.yield(&1, 0)))
      send(holder.pid, :release_writer)

      assert {:ok, :ok} = Task.await(holder)
      Enum.each(queued_writers, &Task.await/1)
      assert %{rows: [[3]]} = Repo.query!("SELECT count(*) FROM counters")
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

  defp start_repo!(options) do
    database =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-immediate-#{System.unique_integer([:positive])}.db"
      )

    {:ok, repo} =
      Repo.start_link(
        [name: nil, database: database, pool: DBConnection.ConnectionPool] ++ options
      )

    Process.unlink(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: Supervisor.stop(repo)
      for suffix <- ["", "-shm", "-wal"], do: File.rm(database <> suffix)
    end)

    repo
  end

  defp await_checkout_queue(pool, minimum, attempts \\ 100)

  defp await_checkout_queue(_pool, _minimum, 0), do: flunk("writer never entered pool queue")

  defp await_checkout_queue(pool, minimum, attempts) do
    [%{checkout_queue_length: length}] = DBConnection.get_connection_metrics(pool)

    if length >= minimum do
      :ok
    else
      Process.sleep(5)
      await_checkout_queue(pool, minimum, attempts - 1)
    end
  end
end
