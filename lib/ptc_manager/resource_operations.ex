defmodule PtcManager.ResourceOperations do
  @moduledoc """
  Durable, worker-local admission for expensive commands run by managed agents.

  Repository commands remain ordinary commands outside a managed PtcManager
  context. This context owns only the cooperative scheduling protocol.
  """

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.Operations.{CapacityChange, CapacitySetting, ResourceOperation, Worker}
  alias PtcManager.Repo
  alias PtcManager.RepoTransaction

  @leased_states ~w(starting running cancelling recovery_pending)
  @visible_states ["queued" | @leased_states]

  def request(attrs, now \\ now()) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:queued_at, now)
      |> Map.put_new(:last_heartbeat_at, now)

    case %ResourceOperation{} |> ResourceOperation.changeset(attrs) |> Repo.insert() do
      {:ok, operation} ->
        notify()
        {:ok, operation}

      {:error, changeset} = error ->
        if Keyword.has_key?(changeset.errors, :invocation_id) do
          invocation_id = Map.get(attrs, :invocation_id) || Map.get(attrs, "invocation_id")

          case Repo.get_by(ResourceOperation, invocation_id: invocation_id) do
            nil -> error
            operation -> {:ok, operation}
          end
        else
          error
        end
    end
  end

  def claim_next(worker_id, at \\ now()) do
    result =
      RepoTransaction.immediate(fn ->
        capacity =
          case Repo.one(CapacitySetting) do
            nil -> Application.get_env(:ptc_manager, :operation_capacity, 1)
            setting -> setting.operation_capacity
          end

        used_slots =
          ResourceOperation
          |> where([operation], operation.worker_id == ^worker_id)
          |> where([operation], operation.state in ^@leased_states)
          |> select([operation], operation.slot_number)
          |> Repo.all()
          |> MapSet.new()

        with slot when not is_nil(slot) <-
               Enum.find(1..capacity, &(not MapSet.member?(used_slots, &1))),
             %ResourceOperation{} = operation <- next_queued(worker_id) do
          token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

          operation
          |> ResourceOperation.changeset(%{
            state: "starting",
            slot_number: slot,
            fencing_token: operation.fencing_token + 1,
            attempt_token: token,
            last_heartbeat_at: at,
            wait_duration_ms: duration_ms(operation.queued_at, at)
          })
          |> Repo.update!()
        else
          nil -> :empty
        end
      end)

    case result do
      {:ok, operation} when is_struct(operation, ResourceOperation) ->
        notify()
        {:ok, operation}

      {:ok, :empty} ->
        {:ok, :empty}

      other ->
        other
    end
  end

  def mark_running(id, attempt_token, attrs \\ %{}, at \\ now()) do
    transition(id, attempt_token, ["starting"], fn operation ->
      ResourceOperation.changeset(
        operation,
        Map.merge(attrs, %{
          state: "running",
          started_at: operation.started_at || at,
          last_heartbeat_at: at,
          wait_duration_ms: duration_ms(operation.queued_at, operation.started_at || at)
        })
      )
    end)
  end

  def heartbeat(id, attempt_token, at \\ now()) do
    transition(id, attempt_token, @leased_states, fn operation ->
      attrs =
        if operation.state == "recovery_pending",
          do: %{state: "running", last_heartbeat_at: at, last_error: nil},
          else: %{last_heartbeat_at: at}

      ResourceOperation.changeset(operation, attrs)
    end)
  end

  def heartbeat_queued(id, at \\ now()) do
    result =
      ResourceOperation
      |> where([operation], operation.id == ^id and operation.state == "queued")
      |> Repo.update_all(set: [last_heartbeat_at: at, updated_at: at])

    case result do
      {1, _rows} -> :ok
      _other -> {:error, :operation_not_queued}
    end
  end

  def expire_stale_queued(at \\ now(), stale_after_ms \\ 15_000) do
    cutoff = DateTime.add(at, -stale_after_ms, :millisecond)

    {count, _rows} =
      ResourceOperation
      |> where([operation], operation.state == "queued")
      |> where(
        [operation],
        is_nil(operation.last_heartbeat_at) or operation.last_heartbeat_at < ^cutoff
      )
      |> Repo.update_all(
        set: [
          state: "cancelled",
          cancellation_reason: "The waiting operation wrapper disappeared.",
          finished_at: at,
          updated_at: at
        ]
      )

    if count > 0, do: notify()
    count
  end

  def mark_stale_recovery_pending(at \\ now(), stale_after_ms \\ 15_000) do
    cutoff = DateTime.add(at, -stale_after_ms, :millisecond)

    {count, _rows} =
      ResourceOperation
      |> where([operation], operation.state in ["starting", "running", "cancelling"])
      |> where(
        [operation],
        is_nil(operation.last_heartbeat_at) or operation.last_heartbeat_at < ^cutoff
      )
      |> Repo.update_all(
        set: [
          state: "recovery_pending",
          last_error: "The operation heartbeat stopped; its slot remains fenced during recovery.",
          updated_at: at
        ]
      )

    if count > 0, do: notify()
    count
  end

  def list_recovery_pending do
    ResourceOperation
    |> where([operation], operation.state == "recovery_pending")
    |> order_by([operation], asc: operation.last_heartbeat_at, asc: operation.id)
    |> Repo.all()
  end

  def record_recovery_retry(id, attempt_token, reason, at \\ now(), retry_after_ms \\ 60_000) do
    transition(id, attempt_token, ["recovery_pending"], fn operation ->
      waiting? = String.starts_with?(operation.last_error || "", "Recovery is waiting:")
      escalated? = String.starts_with?(operation.last_error || "", "Operation recovery exceeded")

      cond do
        escalated? ->
          ResourceOperation.changeset(operation, %{})

        waiting? and duration_ms(operation.last_heartbeat_at, at) >= retry_after_ms ->
          ResourceOperation.changeset(operation, %{
            last_error:
              "Operation recovery exceeded its retry bound and requires maintainer attention: #{bounded(reason)}"
          })

        true ->
          ResourceOperation.changeset(operation, %{
            last_error: "Recovery is waiting: #{bounded(reason)}"
          })
      end
    end)
    |> case do
      {:ok, %{last_error: "Operation recovery exceeded" <> _} = operation} ->
        {:escalate, operation}

      other ->
        other
    end
  end

  def record_recovery_error(id, attempt_token, reason) do
    transition(id, attempt_token, ["recovery_pending"], fn operation ->
      ResourceOperation.changeset(operation, %{
        last_error:
          "Operation recovery could not evaluate the fenced slot and requires maintainer attention: #{bounded(inspect(reason))}"
      })
    end)
  end

  def release_recovered(id, attempt_token, reason, at \\ now()) do
    finish(
      id,
      attempt_token,
      %{
        state: "lost",
        exit_status: 75,
        last_error: reason,
        wrapper_pid: nil,
        cgroup_path: nil,
        slot_number: nil
      },
      at
    )
  end

  def finish(id, attempt_token, attrs \\ %{}, at \\ now()) do
    transition(
      id,
      attempt_token,
      ["starting", "running", "cancelling", "recovery_pending"],
      fn operation ->
        exit_status = Map.get(attrs, :exit_status, Map.get(attrs, "exit_status", 0))

        state =
          Map.get(attrs, :state, Map.get(attrs, "state")) ||
            cond do
              operation.state == "cancelling" -> "cancelled"
              exit_status == 0 -> "completed"
              true -> "failed"
            end

        ResourceOperation.changeset(
          operation,
          Map.merge(attrs, %{
            state: state,
            exit_status: exit_status,
            finished_at: at,
            last_heartbeat_at: at,
            run_duration_ms: duration_ms(operation.started_at || at, at)
          })
        )
      end
    )
  end

  def cancel(id, reason, at \\ now()) do
    result =
      RepoTransaction.immediate(fn ->
        operation = Repo.get!(ResourceOperation, id)

        cond do
          ResourceOperation.terminal_state?(operation.state) ->
            operation

          operation.state == "queued" ->
            operation
            |> ResourceOperation.changeset(%{
              state: "cancelled",
              cancellation_reason: reason,
              finished_at: at
            })
            |> Repo.update!()

          true ->
            operation
            |> ResourceOperation.changeset(%{
              state: "cancelling",
              cancellation_reason: reason,
              last_heartbeat_at: at
            })
            |> Repo.update!()
        end
      end)

    case result do
      {:ok, operation} ->
        notify()
        {:ok, operation}

      other ->
        other
    end
  end

  def list_current do
    ResourceOperation
    |> where([operation], operation.state in ^@visible_states)
    |> order_by([operation],
      desc: operation.priority,
      asc: operation.queued_at,
      asc: operation.id
    )
    |> preload([:repository, :worker, :agent_run, :job, :agent_action])
    |> Repo.all()
  end

  @doc "Counts expensive operations that currently occupy an operation slot."
  def count_active do
    ResourceOperation
    |> where([operation], operation.state in ^@leased_states)
    |> Repo.aggregate(:count)
  end

  def list_recent(limit \\ 20) do
    ResourceOperation
    |> where([operation], operation.state not in ^@visible_states)
    |> order_by([operation], desc: operation.finished_at, desc: operation.id)
    |> limit(^limit)
    |> preload([:repository, :worker, :agent_run, :job, :agent_action])
    |> Repo.all()
  end

  def statistics(opts \\ []) do
    to = Keyword.get(opts, :to, now())
    from = Keyword.get(opts, :from, DateTime.add(to, -7, :day))
    worker_id = Keyword.get(opts, :worker_id)
    repository_id = Keyword.get(opts, :repository_id)
    label = Keyword.get(opts, :label)

    operations =
      ResourceOperation
      |> where([operation], operation.finished_at >= ^from and operation.finished_at <= ^to)
      |> where([operation], operation.state in ["completed", "failed", "cancelled", "lost"])
      |> maybe_where(:worker_id, worker_id)
      |> maybe_where(:repository_id, repository_id)
      |> maybe_where(:label, label)
      |> Repo.all()

    durations = values(operations, :run_duration_ms)
    waits = values(operations, :wait_duration_ms)
    peaks = values(operations, :peak_memory_bytes)
    capacity_ms = capacity_milliseconds(worker_id, from, to)
    busy_ms = Enum.sum(durations)

    %{
      count: length(operations),
      succeeded: Enum.count(operations, &(&1.state == "completed" and &1.exit_status == 0)),
      success_rate:
        optional_ratio(
          Enum.count(operations, &(&1.state == "completed" and &1.exit_status == 0)),
          length(operations)
        ),
      total_duration_ms: busy_ms,
      average_duration_ms: average(durations),
      p20_duration_ms: percentile(durations, 20),
      p50_duration_ms: percentile(durations, 50),
      p80_duration_ms: percentile(durations, 80),
      max_duration_ms: maximum(durations),
      average_wait_ms: average(waits),
      p80_wait_ms: percentile(waits, 80),
      p80_peak_memory_bytes: percentile(peaks, 80),
      max_peak_memory_bytes: maximum(peaks),
      utilization: ratio(busy_ms, capacity_ms)
    }
  end

  def record_capacity_change(%CapacitySetting{} = setting, at \\ now()) do
    worker_rows =
      Worker
      |> select([worker], %{
        worker_id: worker.id,
        worker_incarnation_id: worker.worker_incarnation_id
      })
      |> Repo.all()

    rows = [%{worker_id: nil, worker_incarnation_id: nil} | worker_rows]
    inserted_at = at

    rows =
      Enum.map(rows, fn row ->
        Map.merge(row, %{
          light_agent_capacity: setting.light_agent_capacity,
          heavy_agent_capacity: setting.heavy_agent_capacity,
          operation_capacity: setting.operation_capacity,
          effective_at: at,
          inserted_at: inserted_at
        })
      end)

    Repo.insert_all(CapacityChange, rows)
    :ok
  end

  def percentile([], _rank), do: nil

  def percentile(values, rank) when rank >= 0 and rank <= 100 do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * rank / 100) - 1, 0)
    Enum.at(sorted, index)
  end

  defp transition(id, token, allowed_states, changeset_fun) do
    result =
      RepoTransaction.immediate(fn ->
        case Repo.get(ResourceOperation, id) do
          %ResourceOperation{} = operation ->
            cond do
              operation.attempt_token == token and operation.state in allowed_states ->
                operation |> changeset_fun.() |> Repo.update!()

              ResourceOperation.terminal_state?(operation.state) ->
                operation

              true ->
                Repo.rollback(:stale_operation_lease)
            end

          nil ->
            Repo.rollback(:operation_not_found)
        end
      end)

    case result do
      {:ok, operation} ->
        notify()
        {:ok, operation}

      other ->
        other
    end
  end

  defp next_queued(worker_id) do
    ResourceOperation
    |> where([operation], operation.worker_id == ^worker_id and operation.state == "queued")
    |> order_by([operation],
      desc: operation.priority,
      asc: operation.queued_at,
      asc: operation.id
    )
    |> limit(1)
    |> Repo.one()
  end

  defp capacity_milliseconds(worker_id, from, to) do
    query =
      CapacityChange
      |> where([change], change.effective_at <= ^to)
      |> order_by([change], asc: change.effective_at, asc: change.id)

    changes =
      if worker_id,
        do:
          query
          |> where([change], is_nil(change.worker_id) or change.worker_id == ^worker_id)
          |> Repo.all(),
        else: query |> where([change], is_nil(change.worker_id)) |> Repo.all()

    current_capacity = Application.get_env(:ptc_manager, :operation_capacity, 1)

    baseline =
      Enum.filter(changes, &(DateTime.compare(&1.effective_at, from) != :gt)) |> List.last()

    capacity = if baseline, do: baseline.operation_capacity, else: current_capacity
    events = Enum.filter(changes, &(DateTime.compare(&1.effective_at, from) == :gt))

    {sum, cursor, capacity} =
      Enum.reduce(events, {0, from, capacity}, fn change, {sum, cursor, capacity} ->
        {sum + duration_ms(cursor, change.effective_at) * capacity, change.effective_at,
         change.operation_capacity}
      end)

    sum + duration_ms(cursor, to) * capacity
  end

  defp maybe_where(query, _field, nil), do: query

  defp maybe_where(query, field, value),
    do: where(query, [operation], field(operation, ^field) == ^value)

  defp values(operations, field),
    do: operations |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1)

  defp average([]), do: nil
  defp average(values), do: round(Enum.sum(values) / length(values))
  defp maximum([]), do: nil
  defp maximum(values), do: Enum.max(values)
  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator
  defp optional_ratio(_numerator, 0), do: nil
  defp optional_ratio(numerator, denominator), do: numerator / denominator
  defp duration_ms(nil, _to), do: 0
  defp duration_ms(_from, nil), do: 0
  defp duration_ms(from, to), do: max(DateTime.diff(to, from, :millisecond), 0)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp bounded(value), do: value |> to_string() |> String.trim() |> String.slice(0, 700)
  defp notify, do: Operations.notify_changed(__MODULE__)
end
