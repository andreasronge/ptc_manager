defmodule PtcManager.Reviews.CancelWorker do
  use Oban.Worker, queue: :automations, max_attempts: 1
  import Ecto.Query
  alias PtcManager.{Repo, Operations}
  alias PtcManager.Operations.{Job, AgentRun}

  def perform(%Oban.Job{args: %{"job_id" => id, "generation" => generation}}) do
    if PtcManager.OperationalMode.reconciliation_allowed?() and
         not Application.get_env(:ptc_manager, :demo_mode, false),
       do: stop(id, generation),
       else: {:snooze, 30}
  end

  defp stop(id, generation) do
    job = Repo.get!(Job, id)

    if job.review_state in ["cancelled", "manual"] and job.review_generation == generation do
      run =
        Repo.one(
          from r in AgentRun, where: r.job_id == ^id and r.fencing_token == ^job.fencing_token
        )

      if run && is_binary(run.herdr_pane) do
        case close_owned_pane(run) do
          :ok ->
            run
            |> AgentRun.changeset(%{
              state: "lost",
              ended_at: DateTime.utc_now(),
              status_text: "Stopped by maintainer; workspace preserved."
            })
            |> Repo.update!()

          _ ->
            job
            |> Job.changeset(%{
              last_error:
                "The retained pane could not be closed. Inspect it on the worker before editing files."
            })
            |> Repo.update!()
        end
      end

      Operations.notify_changed(__MODULE__)
    end

    :ok
  end

  defp close_owned_pane(run) do
    with {:ok, output} <- PtcManager.Herdr.Command.run(["agent", "get", run.agent_name]),
         {:ok, data} <- Jason.decode(output),
         true <- get_in(data, ["result", "agent", "pane_id"]) == run.herdr_pane do
      PtcManager.Herdr.Client.close_pane(run.herdr_pane)
    else
      _ -> {:error, :agent_identity_unconfirmed}
    end
  end
end
