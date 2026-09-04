defmodule PtcManagerWeb.AgentCancel do
  @moduledoc """
  Shared two-step cancel of one running implementation agent.

  Both the Delivery board and Operations offer the same button, so the state
  predicate and the maintainer-facing wording live here rather than in either
  LiveView.
  """

  alias PtcManager.Operations

  @cancellable_job_states ~w(starting working idle blocked)

  @doc "True when this card's job is still in an agent phase a person may end."
  def cancellable?(%{active_job: job, agent_run: run}), do: cancellable?(job, run)
  def cancellable?(_item), do: false

  def cancellable?(%{state: state}, %{}) when state in @cancellable_job_states, do: true
  def cancellable?(_job, _run), do: false

  @doc "Cancels the job and returns the flash kind and message to show."
  def cancel(job_id, actor) when is_binary(job_id) do
    case Integer.parse(job_id) do
      {parsed, ""} -> cancel(parsed, actor)
      _invalid -> {:error, "That agent could not be found."}
    end
  end

  def cancel(job_id, actor) when is_integer(job_id) do
    case Operations.cancel_running_job(job_id, actor) do
      {:ok, _job} ->
        {:info, "The agent was cancelled. Its worktree is kept for you to inspect."}

      {:ok, _job, {:pane_close_failed, _reason}} ->
        {:error,
         "The job was cancelled and its worktree kept, but the Herdr pane did not close. Close it on the worker."}

      {:error, :job_not_cancellable} ->
        {:error,
         "This job has left its agent phase; PtcManager owns the remaining steps and they cannot be cancelled here."}

      {:error, _reason} ->
        {:error, "The agent could not be cancelled."}
    end
  end
end
