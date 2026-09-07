defmodule PtcManager.Reviews.Launch do
  @moduledoc "Durable ownership of a continuation identity before its external launch."
  alias PtcManager.{Repo, RepoTransaction, Reviews}
  alias PtcManager.Operations.{Job, AgentRun, WorktreeAllocation}

  def current?(current, expected) do
    Reviews.active_job?(current) and current.fencing_token == expected.fencing_token and
      current.review_state == "resume_pending" and
      current.review_generation == expected.review_generation and
      not is_nil(current.review_resume_expires_at) and
      DateTime.compare(current.review_resume_expires_at, DateTime.utc_now()) == :gt
  end

  def reserve(job, run, pane, workspace, kind, name) do
    RepoTransaction.immediate(fn ->
      current = Repo.get!(Job, job.id)
      unless current?(current, job), do: Repo.rollback(:stale_continuation)

      owned =
        run
        |> AgentRun.changeset(%{
          state: "starting",
          ended_at: nil,
          agent_name: name,
          herdr_pane: pane,
          external_key: nil
        })
        |> Repo.update!()

      job.worktree_allocation
      |> WorktreeAllocation.changeset(%{
        herdr_workspace: workspace,
        agent_kind: kind,
        state: "active"
      })
      |> Repo.update!()

      owned
    end)
  end
end
