defmodule PtcManager.Reviews.CancelWorker do
  use Oban.Worker, queue: :automations, max_attempts: 1

  def perform(%Oban.Job{args: %{"job_id" => id, "generation" => generation}}) do
    if PtcManager.OperationalMode.reconciliation_allowed?() and
         not Application.get_env(:ptc_manager, :demo_mode, false) do
      adapter =
        Application.get_env(
          :ptc_manager,
          :review_resume_adapter,
          PtcManager.Dispatch.HerdrAdapter
        )

      case PtcManager.Reviews.Recovery.stop(id, generation, adapter) do
        {:error, reason} when reason in [:recovery_busy, :database_busy] -> {:snooze, 10}
        _ -> :ok
      end
    else
      {:snooze, 30}
    end
  end
end
