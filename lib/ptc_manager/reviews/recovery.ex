defmodule PtcManager.Reviews.Recovery do
  @moduledoc "Fences the external stop phase separately from admission of a new writer."
  import Ecto.Query
  alias PtcManager.{Repo, RepoTransaction}
  alias PtcManager.Operations.{Job, AgentRun}

  def prepare(id, generation, adapter), do: recover(id, generation, adapter, :resume)
  def stop(id, generation, adapter), do: recover(id, generation, adapter, :stop)

  defp recover(id, generation, adapter, mode) do
    result =
      with {:ok, job} <- claim(id, generation, mode) do
        outcome =
          try do
            if mode == :stop,
              do: adapter.stop_review_agent(job, true),
              else: adapter.stop_review_agent(job)
          rescue
            _ -> {:error, :retained_agent_unconfirmed}
          end

        finish(job, outcome, mode)
      end

    PtcManager.Operations.notify_changed(__MODULE__)
    result
  end

  defp claim(id, generation, mode) do
    RepoTransaction.immediate(fn ->
      job =
        Repo.get!(Job, id)
        |> Repo.preload([:agent_runs, :repository, :issue, worktree_allocation: :worker])

      unless admissible?(job, mode) and job.review_generation == generation,
        do: Repo.rollback(:stale_continuation)

      if job.review_resume_expires_at do
        if mode == :resume, do: Repo.rollback(:stale_continuation)

        if DateTime.compare(job.review_resume_expires_at, DateTime.utc_now()) == :gt,
          do: Repo.rollback(:recovery_busy)
      end

      unless is_nil(job.review_recovery_expires_at), do: Repo.rollback(:recovery_busy)

      unless job.worktree_allocation && job.worktree_allocation.state != "removed",
        do: Repo.rollback(:retained_workspace_not_ready)

      job
      |> Job.changeset(%{review_recovery_expires_at: DateTime.add(DateTime.utc_now(), 120)})
      |> Repo.update!()
    end)
  end

  defp admissible?(job, :resume),
    do: PtcManager.Reviews.active_job?(job) and job.review_state == "resume_pending"

  defp admissible?(job, :stop), do: job.review_state in ~w(manual cancelled)

  defp finish(job, outcome, mode) do
    RepoTransaction.immediate(fn ->
      current = Repo.get!(Job, job.id)

      unless admissible?(current, mode) and
               current.review_generation == job.review_generation and
               current.review_recovery_expires_at == job.review_recovery_expires_at,
             do: Repo.rollback(:stale_continuation)

      if outcome == :ok do
        from(r in AgentRun,
          where:
            r.job_id == ^job.id and r.role == "implementer" and
              r.fencing_token == ^job.fencing_token
        )
        |> Repo.update_all(
          set: [state: "lost", ended_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
        )

        current
        |> Job.changeset(%{
          state: if(PtcManager.Reviews.active_job?(current), do: "blocked", else: current.state),
          review_recovery_expires_at: nil,
          review_resume_expires_at: nil,
          last_error: nil,
          reconciling_at: nil,
          absence_observed_at: nil
        })
        |> Repo.update!()
      else
        current
        |> Job.changeset(%{
          review_state: if(mode == :resume, do: "paused", else: current.review_state),
          review_recovery_expires_at: nil,
          review_resume_expires_at: nil,
          last_error:
            "Retained agent could not be confirmed stopped; work is preserved. Inspect its identity before continuing."
        })
        |> Repo.update!()

        {:recovery_failed, outcome}
      end
    end)
  end
end
