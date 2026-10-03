defmodule PtcManager.RepoTransaction do
  @moduledoc """
  Write transactions that take SQLite's write lock before they read anything.

  A deferred transaction begins as a reader and has to upgrade the moment it
  first writes. In WAL mode SQLite refuses that upgrade outright, without
  consulting `busy_timeout`, once another connection has committed since the
  read began: waiting cannot repair a stale snapshot, only starting over can.
  The refusal therefore surfaces on the writing statement rather than on
  `BEGIN`, which is how it reached supervised processes and terminated them.
  `BEGIN IMMEDIATE` takes the write lock up front, where `busy_timeout` applies
  and a waiting writer succeeds instead of failing.

  `PtcManager.Repo` now begins every transaction that way by default; this
  module remains for callers that want a busy database reported as a value.
  """

  alias PtcManager.Repo

  def immediate(operation) when is_function(operation, 0) or is_struct(operation, Ecto.Multi) do
    Repo.transaction(operation, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if busy?(error) do
        {:error, :database_busy}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  # SQLite spells one condition two ways, and only "database is locked" is
  # raised by `BEGIN`. A statement that cannot take the lock reports "Database
  # busy" instead, so a guard written around the `BEGIN IMMEDIATE` statement
  # never matched the errors that were actually killing callers. Nothing is
  # committed either way, because the transaction is rolled back before the
  # error reaches here, so both are safe to report as a busy database.
  @doc false
  def busy?(%Exqlite.Error{message: message}) when is_binary(message) do
    normalised = String.downcase(message)

    String.contains?(normalised, "database is locked") or
      String.contains?(normalised, "database busy")
  end

  def busy?(_error), do: false
end
