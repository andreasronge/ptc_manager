defmodule PtcManager.Reviews.Worker do
  use Oban.Worker, queue: :reviews, max_attempts: 1
  alias PtcManager.{Reviews, OperationalMode}
  @impl true
  def perform(%Oban.Job{args: %{"round_id" => id}}) do
    if OperationalMode.reconciliation_allowed?() and
         not Application.get_env(:ptc_manager, :demo_mode, false) do
      case Reviews.claim(id) do
        {:ok, round} ->
          adapter = Application.get_env(:ptc_manager, :review_adapter, PtcManager.Reviews.Adapter)

          try do
            case adapter.review(round) do
              {:ok, result} ->
                case Reviews.complete(id, result) do
                  {:ok, _} ->
                    :ok

                  {:error, reason} ->
                    Reviews.fail(id, reason)
                    :ok
                end

              {:error, reason} ->
                Reviews.fail(id, reason)
                :ok
            end
          rescue
            _ ->
              Reviews.fail(id, :reviewer_unavailable)
              :ok
          end

        {:error, :database_busy} ->
          {:snooze, 10}

        {:error, _} ->
          :ok
      end
    else
      {:snooze, 30}
    end
  end
end
