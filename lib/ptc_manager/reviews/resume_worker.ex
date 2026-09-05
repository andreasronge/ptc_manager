defmodule PtcManager.Reviews.ResumeWorker do
  use Oban.Worker, queue: :automations, max_attempts: 1
  alias PtcManager.{Repo, RepoTransaction}
  alias PtcManager.Operations.Job
  @impl true
  def perform(%Oban.Job{args: %{"job_id" => id, "generation" => generation}}) do
    if PtcManager.OperationalMode.active?() and
         not Application.get_env(:ptc_manager, :demo_mode, false),
       do: resume(id, generation),
       else: {:snooze, 30}
  end

  defp resume(id, generation) do
    job =
      Repo.get!(Job, id) |> Repo.preload([:repository, :issue, :worktree_allocation, :agent_runs])

    if job.review_state == "resume_pending" and job.review_generation == generation do
      adapter =
        Application.get_env(
          :ptc_manager,
          :review_resume_adapter,
          PtcManager.Dispatch.HerdrAdapter
        )

      outcome =
        try do
          adapter.resume_review_job(job)
        rescue
          _ -> {:error, :continuation_failed}
        end

      RepoTransaction.immediate(fn ->
        current = Repo.get!(Job, id)

        if current.review_state in ["resume_pending", "changes_requested"] and
             current.review_generation == generation do
          state = if match?({:ok, _}, outcome), do: "changes_requested", else: "paused"

          current
          |> Job.changeset(%{
            review_state: state,
            review_resume_expires_at: nil,
            last_error:
              if(state == "paused", do: "Continuation could not start; the work is preserved.")
          })
          |> Repo.update!()
        end
      end)

      PtcManager.ExecutionProfiles.notify()
    end

    :ok
  end
end
