defmodule PtcManager.DeploymentCanary do
  @moduledoc "Runs the one allowlisted, read-only adapter check before deployment activation."

  import Ecto.Query

  alias PtcManager.Manager
  alias PtcManager.OperationalMode
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentRun, Issue, Worker}
  alias PtcManager.Repo

  defmodule Adapter do
    @moduledoc false
    @behaviour PtcManager.Manager.Adapter

    @impl true
    def analyze(issue) do
      {:ok,
       %{
         plain_summary: "Deployment canary analyzed issue ##{issue.number} read-only.",
         why_it_matters:
           "This proves the deployed manager path can validate and persist a result.",
         scope: "small",
         risk: "low",
         readiness: "ready",
         technical_evidence: "PtcManager.DeploymentCanary.Adapter completed without credentials."
       }}
    end
  end

  def run(invocation_id, opts \\ []) when is_binary(invocation_id) do
    Process.put({__MODULE__, :run}, nil)
    adapter = Keyword.get(opts, :adapter, Adapter)

    try do
      result =
        with :ok <- OperationalMode.admit_canary(invocation_id),
             :ok <- OperationalMode.claim_canary(invocation_id),
             %Issue{} = issue <- canary_issue(),
             %Worker{} = worker <- canary_worker(),
             {:ok, run} <- start_run(worker, issue, invocation_id),
             :ok <- remember_run(run),
             {:ok, proposal} <-
               Manager.investigate_issue(
                 issue.id,
                 canary_id: invocation_id,
                 adapter: adapter
               ),
             {:ok, _run} <- finish_run(run, "done", "Read-only deployment canary passed."),
             :ok <- OperationalMode.mark_canary_passed(invocation_id) do
          {:ok, %{run_id: run.id, issue_id: issue.id, proposal_id: proposal.id}}
        else
          nil -> {:error, :canary_fixture_unavailable}
          {:error, _reason} = error -> error
        end

      case result do
        {:ok, _summary} = success ->
          success

        {:error, reason} = error ->
          fail_remembered_run(reason)
          OperationalMode.enter_maintenance()
          error
      end
    rescue
      exception ->
        fail_closed({:exception, exception.__struct__})
    catch
      kind, reason ->
        fail_closed({kind, reason})
    after
      Process.delete({__MODULE__, :run})
    end
  end

  def activate(invocation_id, opts \\ []) when is_binary(invocation_id) do
    OperationalMode.activate_canary(invocation_id, opts)
  end

  defp canary_issue do
    Issue
    |> where([issue], issue.state == "open")
    |> order_by([issue], asc: issue.id)
    |> limit(1)
    |> Repo.one()
  end

  defp canary_worker do
    Worker
    |> order_by(
      [worker],
      asc: fragment("CASE WHEN ? = 'online' THEN 0 ELSE 1 END", worker.status),
      asc: worker.id
    )
    |> limit(1)
    |> Repo.one()
  end

  defp start_run(worker, issue, invocation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Operations.create_agent_run(%{
      worker_id: worker.id,
      role: "manager",
      state: "working",
      status_text: "Checking the read-only manager adapter before ordinary work resumes.",
      agent_name: "deploy_canary_#{String.slice(invocation_id, 0, 48)}",
      external_key: "deployment-canary:#{invocation_id}",
      herdr_workspace: "deployment-canary-issue-#{issue.number}",
      started_at: now,
      last_heartbeat_at: now
    })
  end

  defp remember_run(run) do
    Process.put({__MODULE__, :run}, run)
    :ok
  end

  defp fail_remembered_run(reason) do
    case Process.get({__MODULE__, :run}) do
      %AgentRun{state: "working"} = run ->
        finish_run(run, "failed", "Read-only deployment canary failed: #{reason_text(reason)}")

      _run ->
        :ok
    end
  end

  defp fail_closed(reason) do
    fail_remembered_run(reason)
    OperationalMode.enter_maintenance()
    {:error, reason}
  end

  defp finish_run(run, state, status_text) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Operations.update_agent_run(run, %{
      state: state,
      status_text: status_text,
      last_heartbeat_at: now,
      ended_at: now
    })
  end

  defp reason_text(reason) do
    reason
    |> inspect(limit: 4, printable_limit: 120)
    |> String.slice(0, 150)
  end
end
