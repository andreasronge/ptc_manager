defmodule PtcManager.Reviews.SnapshotCleanupWorker do
  use Oban.Worker,
    queue: :automations,
    max_attempts: 5,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  def perform(%Oban.Job{args: %{"round_id" => id}}) do
    if PtcManager.OperationalMode.reconciliation_allowed?() and
         not Application.get_env(:ptc_manager, :demo_mode, false) do
      case PtcManager.Reviews.Snapshots.cleanup(id) do
        :ok -> :ok
        {:error, _} -> {:snooze, 60}
      end
    else
      {:snooze, 30}
    end
  end
end
