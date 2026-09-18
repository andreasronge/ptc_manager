defmodule PtcManager.DatabaseDiagnostics do
  @moduledoc """
  Bounded diagnostics for SQLite lock waits and transactions.

  Ecto's normal error log identifies the statement that lost a writer-lock
  race, but not the workload that held the lock. This handler records slow
  writer acquisition, pool queueing, and the elapsed time between a successful
  `begin` and its matching commit or rollback without logging SQL parameters.
  """

  use GenServer

  require Logger

  @handler_id "ptc-manager-database-diagnostics"
  @event [:ptc_manager, :repo, :query]
  @transaction_key {__MODULE__, :transaction}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)

    Logger.info(
      "SQLite diagnostics attached: slow threshold=#{slow_ms()}ms, " <>
        "busy timeout=#{repo_config(:busy_timeout, 0)}ms, pool size=#{repo_config(:pool_size, 1)}"
    )

    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(@event, measurements, metadata, _config) do
    query = metadata |> Map.get(:query, "") |> to_string() |> String.downcase()

    case query do
      "begin" -> transaction_started(measurements, metadata)
      outcome when outcome in ["commit", "rollback"] -> transaction_finished(outcome)
      _query -> log_slow_query(measurements, metadata)
    end
  end

  @doc "Adds a safe workload name to database diagnostics emitted while `operation` runs."
  def with_context(name, operation) when is_binary(name) and is_function(operation, 0) do
    previous = Logger.metadata()
    Logger.metadata(database_work: name)

    try do
      operation.()
    after
      Logger.reset_metadata(previous)
    end
  end

  defp transaction_started(measurements, metadata) do
    duration_ms = milliseconds(measurements[:total_time])

    if duration_ms >= slow_ms() do
      Logger.warning(
        "SQLite writer acquisition was slow: duration_ms=#{duration_ms} " <>
          "result=#{result_name(metadata[:result])} owner=#{owner()}"
      )
    end

    if match?({:ok, _result}, metadata[:result]) do
      case Process.get(@transaction_key) do
        nil ->
          Process.put(@transaction_key, {1, System.monotonic_time(), owner()})

        {depth, started_at, owner} ->
          Process.put(@transaction_key, {depth + 1, started_at, owner})
      end
    end
  end

  defp transaction_finished(outcome) do
    case Process.get(@transaction_key) do
      {depth, started_at, owner} when depth > 1 ->
        Process.put(@transaction_key, {depth - 1, started_at, owner})

      {1, started_at, owner} ->
        Process.delete(@transaction_key)

        duration_ms =
          System.monotonic_time()
          |> Kernel.-(started_at)
          |> System.convert_time_unit(:native, :millisecond)

        if duration_ms >= slow_ms() do
          Logger.warning(
            "SQLite transaction was slow: duration_ms=#{duration_ms} outcome=#{outcome} " <>
              "owner=#{owner}"
          )
        end

      nil ->
        :ok
    end
  end

  defp log_slow_query(measurements, metadata) do
    total_ms = milliseconds(measurements[:total_time])
    queue_ms = milliseconds(measurements[:queue_time])

    if total_ms >= slow_ms() or queue_ms >= slow_ms() do
      Logger.warning(
        "SQLite query was slow: total_ms=#{total_ms} queue_ms=#{queue_ms} " <>
          "source=#{inspect(metadata[:source])} result=#{result_name(metadata[:result])} " <>
          "owner=#{owner()}"
      )
    end
  end

  defp owner do
    metadata = Logger.metadata()
    work = Keyword.get(metadata, :database_work, "unlabelled")
    registered_name = Process.info(self(), :registered_name) |> elem(1)
    label = Process.info(self(), :label) |> elem(1)
    initial_call = Process.info(self(), :initial_call) |> elem(1)

    inspect(%{
      work: work,
      pid: inspect(self()),
      registered_name: registered_name,
      label: label,
      initial_call: initial_call
    })
  end

  defp result_name({:ok, _result}), do: "ok"
  defp result_name({:error, %{__struct__: module}}), do: inspect(module)
  defp result_name({:error, reason}), do: inspect(reason)
  defp result_name(_result), do: "unknown"

  defp milliseconds(nil), do: 0

  defp milliseconds(native) when is_integer(native),
    do: System.convert_time_unit(native, :native, :millisecond)

  defp slow_ms,
    do: Application.get_env(:ptc_manager, :database_slow_query_ms, 1_000)

  defp repo_config(key, default) do
    :ptc_manager
    |> Application.get_env(PtcManager.Repo, [])
    |> Keyword.get(key, default)
  end
end
