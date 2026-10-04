defmodule PtcManager.TransactionAssertions do
  @moduledoc false

  import ExUnit.Assertions

  def assert_no_transaction_reads(operation) when is_function(operation, 0) do
    handler = "transaction-reads-#{System.unique_integer([:positive])}"
    owner = self()
    transaction_key = {__MODULE__, handler, :transaction}

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_manager, :repo, :query],
        &__MODULE__.track_transaction_reads/4,
        {owner, transaction_key}
      )

    try do
      result = operation.()

      receive do
        {:transaction_read, source} ->
          flunk("unexpected database read inside transaction from #{inspect(source)}")
      after
        0 -> result
      end
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def track_transaction_reads(_event, _measurements, metadata, {pid, transaction_key}) do
    query = to_string(metadata[:query])

    case String.downcase(query) do
      "begin" ->
        Process.put(transaction_key, true)

      outcome when outcome in ["commit", "rollback"] ->
        Process.delete(transaction_key)

      _query ->
        if Process.get(transaction_key) == true and
             (String.starts_with?(query, "SELECT") or String.starts_with?(query, "PRAGMA")) do
          send(pid, {:transaction_read, metadata[:source]})
        end
    end
  end
end
