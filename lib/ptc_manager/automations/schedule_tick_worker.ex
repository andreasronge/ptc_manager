defmodule PtcManager.Automations.ScheduleTickWorker do
  @moduledoc "Materializes due persisted schedules without bypassing the domain queue."
  use Oban.Worker, queue: :automations, max_attempts: 10, unique: [period: 50]

  alias PtcManager.Automations

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Automations.due_schedule_triggers(now)
    |> Enum.reduce_while(:ok, fn trigger, :ok ->
      occurrence = DateTime.to_iso8601(trigger.next_run_at)

      case Automations.run_trigger(trigger, "scheduler", now: now, occurrence_key: occurrence) do
        {:ok, _invocation} ->
          # Coalesce an outage to one run and schedule from the current instant;
          # never replay a backlog of stale nightly/daily occurrences.
          case Automations.advance_schedule(trigger, now) do
            {:ok, _trigger} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, inspect(reason)}}
          end

        {:error, :agent_action_already_active} ->
          {:halt, {:snooze, 60}}

        {:error, reason} ->
          {:halt, {:error, inspect(reason)}}
      end
    end)
  end
end
