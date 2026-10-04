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
  @transactions_table __MODULE__.OpenTransactions

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    ensure_transactions_table()
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)

    Logger.info(
      "SQLite diagnostics attached: slow threshold=#{slow_ms()}ms, " <>
        "busy timeout=#{repo_config(:busy_timeout, 0)}ms, " <>
        "request timeout=#{repo_config(:timeout, 0)}ms, " <>
        "queue target=#{repo_config(:queue_target, 0)}ms, " <>
        "queue interval=#{repo_config(:queue_interval, 0)}ms, " <>
        "pool size=#{repo_config(:pool_size, 1)}"
    )

    log_sqlite_settings()
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

  @doc "Adds a safe phase name and timing to the current database workload."
  def with_phase(phase, operation) when is_binary(phase) and is_function(operation, 0) do
    previous = Logger.metadata()
    started_at = System.monotonic_time()
    Logger.metadata(database_phase: phase)
    refresh_transaction_owner()

    try do
      operation.()
    after
      duration_ms = elapsed_ms(started_at)

      if duration_ms >= slow_ms() do
        Logger.warning(
          "SQLite workload phase was slow: phase=#{phase} duration_ms=#{duration_ms} " <>
            "transaction_id=#{transaction_id()} owner=#{inspect(owner())}"
        )
      end

      Logger.reset_metadata(previous)
      refresh_transaction_owner()
    end
  end

  @doc "Starts a supervised task whose database telemetry carries a safe workload name."
  def async_nolink(supervisor, name, operation)
      when is_binary(name) and is_function(operation, 0) do
    Task.Supervisor.async_nolink(supervisor, fn -> with_context(name, operation) end)
  end

  defp transaction_started(measurements, metadata) do
    total_ms = milliseconds(measurements[:total_time])
    queue_ms = milliseconds(measurements[:queue_time])
    query_ms = milliseconds(measurements[:query_time])

    if queue_ms >= slow_ms() do
      Logger.warning(
        "SQLite pool checkout was slow: queue_ms=#{queue_ms} total_ms=#{total_ms} " <>
          "result=#{result_name(metadata[:result])} owner=#{inspect(owner())}"
      )
    end

    if is_integer(measurements[:query_time]) and query_ms >= slow_ms() do
      Logger.warning(
        "SQLite writer acquisition was slow: query_ms=#{query_ms} queue_ms=#{queue_ms} " <>
          "result=#{result_name(metadata[:result])} owner=#{inspect(owner())} " <>
          "open_transactions=#{inspect(open_transaction_summaries())}"
      )
    end

    if match?({:ok, _result}, metadata[:result]) do
      case Process.get(@transaction_key) do
        nil ->
          started_at = System.monotonic_time()
          transaction_id = System.unique_integer([:positive, :monotonic])
          owner = owner()
          Process.put(@transaction_key, {1, started_at, owner, transaction_id})
          register_transaction(started_at, owner, transaction_id)

        {depth, started_at, owner, transaction_id} ->
          Process.put(@transaction_key, {depth + 1, started_at, owner, transaction_id})
      end
    end
  end

  defp transaction_finished(outcome) do
    case Process.get(@transaction_key) do
      {depth, started_at, owner, transaction_id} when depth > 1 ->
        Process.put(@transaction_key, {depth - 1, started_at, owner, transaction_id})

      {1, started_at, owner, transaction_id} ->
        Process.delete(@transaction_key)
        unregister_transaction()

        duration_ms = elapsed_ms(started_at)

        if duration_ms >= slow_ms() do
          Logger.warning(
            "SQLite transaction was slow: duration_ms=#{duration_ms} outcome=#{outcome} " <>
              "transaction_id=#{transaction_id} owner=#{inspect(owner)}"
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
          "source=#{inspect(metadata[:source])} statement=#{statement(metadata[:query])} " <>
          "result=#{result_name(metadata[:result])} transaction_id=#{transaction_id()} " <>
          "owner=#{inspect(owner())}"
      )
    end
  end

  @doc false
  def open_transactions do
    ensure_transactions_table()

    @transactions_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn {pid, started_at, owner, transaction_id} ->
      if Process.alive?(pid) do
        [
          %{
            pid: pid,
            age_ms: elapsed_ms(started_at),
            owner: owner,
            transaction_id: transaction_id
          }
        ]
      else
        :ets.delete(@transactions_table, pid)
        []
      end
    end)
    |> Enum.sort_by(& &1.transaction_id)
  end

  defp open_transaction_summaries do
    Enum.map(open_transactions(), fn transaction ->
      %{
        age_ms: transaction.age_ms,
        owner: transaction.owner,
        transaction_id: transaction.transaction_id
      }
    end)
  end

  defp register_transaction(started_at, owner, transaction_id) do
    ensure_transactions_table()
    :ets.insert(@transactions_table, {self(), started_at, owner, transaction_id})
  end

  defp unregister_transaction do
    ensure_transactions_table()
    :ets.delete(@transactions_table, self())
  end

  defp refresh_transaction_owner do
    case Process.get(@transaction_key) do
      {depth, started_at, _owner, transaction_id} ->
        current_owner = owner()
        Process.put(@transaction_key, {depth, started_at, current_owner, transaction_id})
        register_transaction(started_at, current_owner, transaction_id)

      nil ->
        :ok
    end
  end

  defp ensure_transactions_table do
    if :ets.whereis(@transactions_table) == :undefined do
      try do
        :ets.new(@transactions_table, [:named_table, :public, :set, read_concurrency: true])
      rescue
        ArgumentError -> @transactions_table
      end
    end

    @transactions_table
  end

  defp transaction_id do
    case Process.get(@transaction_key) do
      {_depth, _started_at, _owner, transaction_id} -> transaction_id
      nil -> "none"
    end
  end

  defp statement(query) do
    query
    |> to_string()
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.downcase()
    |> case do
      operation when operation in ~w(select insert update delete replace pragma with) -> operation
      _other -> "other"
    end
  end

  defp owner do
    metadata = Logger.metadata()

    %{
      work: Keyword.get(metadata, :database_work, "unlabelled"),
      phase: Keyword.get(metadata, :database_phase, "unphased"),
      pid: inspect(self()),
      registered_name: process_info(:registered_name, []),
      label: process_info(:label, :undefined),
      initial_call: process_info(:initial_call, :undefined)
    }
  end

  defp process_info(item, default) do
    case Process.info(self(), item) do
      {^item, value} -> value
      nil -> default
    end
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp log_sqlite_settings do
    settings =
      for pragma <-
            ~w(journal_mode synchronous cache_size cache_spill wal_autocheckpoint locking_mode),
          into: %{} do
        %{rows: [[value]]} = PtcManager.Repo.query!("PRAGMA #{pragma}")
        {pragma, value}
      end

    Logger.info("SQLite runtime settings: #{inspect(settings)}")
  rescue
    error ->
      Logger.warning("SQLite runtime settings unavailable: error=#{inspect(error.__struct__)}")
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
