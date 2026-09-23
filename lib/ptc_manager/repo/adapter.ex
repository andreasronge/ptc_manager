defmodule PtcManager.Repo.Adapter do
  @moduledoc """
  `Ecto.Adapters.SQLite3`, with writers waiting for SQLite's lock outside the
  driver.

  exqlite finalises a statement under its connection's mutex, and a connection
  waiting in SQLite's busy handler holds that mutex for its whole wait. A
  process that holds the write lock and garbage-collects a statement prepared
  on such a waiter stalls until the waiter gives up, and the waiter cannot
  succeed, because it is waiting for that holder. With a 15-second
  `busy_timeout`, every such stall ran to 15 seconds.

  The repo's `:busy_timeout` is therefore a short slice, and the rest of the
  wait happens here, between attempts, where no mutex is held. A `BEGIN`, or a
  statement outside a transaction, that fails because the database is busy is
  retried until `:write_lock_wait` milliseconds have passed. Neither has done
  any work when it fails, so a retry cannot repeat a write. Raw SQL through
  `Repo.query/3`, and a transaction begun inside `Repo.checkout/2`, keep only
  the slice.
  """

  alias PtcManager.RepoTransaction

  @base Ecto.Adapters.SQLite3
  @first_retry_ms 10
  @max_retry_ms 100
  @retried [init: 1, transaction: 3, execute: 5, insert: 6, update: 6, delete: 5, insert_all: 8]

  for {:behaviour, behaviours} <- @base.__info__(:attributes), behaviour <- behaviours do
    @behaviour behaviour
  end

  defmacro __before_compile__(env), do: Ecto.Adapters.SQL.__before_compile__(:exqlite, env)

  for {name, arity} <- @base.__info__(:functions), {name, arity} not in @retried do
    defdelegate unquote(name)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))),
      to: @base
  end

  def init(config) do
    {:ok, child_spec, adapter_meta} = @base.init(config)
    write_lock_wait = Keyword.get(config, :write_lock_wait, 0)
    {:ok, child_spec, Map.put(adapter_meta, :write_lock_wait, write_lock_wait)}
  end

  # A busy `BEGIN` disconnects its connection, so only a transaction that
  # checks out its own connection can try again on a fresh one.
  def transaction(adapter_meta, opts, fun) do
    if @base.checked_out?(adapter_meta) do
      @base.transaction(adapter_meta, opts, fun)
    else
      with_lock_wait(adapter_meta, &busy_begin?/1, fn ->
        @base.transaction(adapter_meta, opts, fun)
      end)
    end
  end

  def execute(adapter_meta, query_meta, query, params, opts) do
    outside_transaction(adapter_meta, fn ->
      @base.execute(adapter_meta, query_meta, query, params, opts)
    end)
  end

  def insert(adapter_meta, schema_meta, params, on_conflict, returning, opts) do
    outside_transaction(adapter_meta, fn ->
      @base.insert(adapter_meta, schema_meta, params, on_conflict, returning, opts)
    end)
  end

  def update(adapter_meta, schema_meta, fields, params, returning, opts) do
    outside_transaction(adapter_meta, fn ->
      @base.update(adapter_meta, schema_meta, fields, params, returning, opts)
    end)
  end

  def delete(adapter_meta, schema_meta, params, returning, opts) do
    outside_transaction(adapter_meta, fn ->
      @base.delete(adapter_meta, schema_meta, params, returning, opts)
    end)
  end

  def insert_all(
        adapter_meta,
        schema_meta,
        header,
        rows,
        on_conflict,
        returning,
        placeholders,
        opts
      ) do
    outside_transaction(adapter_meta, fn ->
      @base.insert_all(
        adapter_meta,
        schema_meta,
        header,
        rows,
        on_conflict,
        returning,
        placeholders,
        opts
      )
    end)
  end

  # Inside a transaction this connection already holds the write lock, and a
  # failed statement may follow others that did work, so it is never retried.
  defp outside_transaction(adapter_meta, operation) do
    if @base.in_transaction?(adapter_meta) do
      operation.()
    else
      with_lock_wait(adapter_meta, &RepoTransaction.busy?/1, operation)
    end
  end

  # Only the `BEGIN` itself: an error raised by the transaction's own work is
  # the caller's, even when it reports a busy database.
  defp busy_begin?(%Exqlite.Error{statement: "BEGIN" <> _} = error),
    do: RepoTransaction.busy?(error)

  defp busy_begin?(_error), do: false

  defp with_lock_wait(adapter_meta, retryable?, operation) do
    deadline = System.monotonic_time(:millisecond) + adapter_meta.write_lock_wait
    attempt(retryable?, operation, deadline, @first_retry_ms)
  end

  defp attempt(retryable?, operation, deadline, delay) do
    case run(retryable?, operation) do
      {:ok, result} ->
        result

      {:busy, error, stacktrace} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          reraise(error, stacktrace)
        else
          Process.sleep(min(delay, remaining))
          attempt(retryable?, operation, deadline, min(delay * 2, @max_retry_ms))
        end
    end
  end

  defp run(retryable?, operation) do
    {:ok, operation.()}
  rescue
    error in Exqlite.Error ->
      if retryable?.(error),
        do: {:busy, error, __STACKTRACE__},
        else: reraise(error, __STACKTRACE__)
  end
end
