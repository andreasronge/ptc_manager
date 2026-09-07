defmodule PtcManager.Reviews.PrepareWorker do
  @moduledoc "Durable backstop for a caller interrupted after review admission."
  use Oban.Worker, queue: :automations, max_attempts: 5

  def perform(%Oban.Job{args: %{"round_id" => id}}) do
    if PtcManager.OperationalMode.reconciliation_allowed?() and
         not Application.get_env(:ptc_manager, :demo_mode, false) do
      case PtcManager.Reviews.prepare_pending(id) do
        {:ok, %PtcManager.Reviews.Round{state: "preparing"}} -> {:snooze, 5}
        {:error, :database_busy} -> {:snooze, 5}
        {:ok, _} -> :ok
        {:error, :stale_review} -> :ok
        error -> error
      end
    else
      {:snooze, 30}
    end
  end
end
