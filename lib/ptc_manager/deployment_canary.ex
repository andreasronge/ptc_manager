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

  @doc """
  Runs the canary under `invocation_id` for `opts[:actor]` (default `canary`).

  Admission is decided first and on its own: a console that is not in
  maintenance refuses the canary without changing its mode, so a stray call
  cannot pause production. Only a canary that was admitted and then failed
  puts the console into maintenance.
  """
  def run(invocation_id, opts \\ []) when is_binary(invocation_id) do
    actor = Keyword.get(opts, :actor, "canary")

    case OperationalMode.admit_canary(invocation_id, actor) do
      :ok -> run_admitted(invocation_id, actor, Keyword.get(opts, :adapter, Adapter))
      {:error, _reason} = refused -> refused
    end
  end

  defp run_admitted(invocation_id, actor, adapter) do
    Process.put({__MODULE__, :run}, nil)

    try do
      result =
        with :ok <- OperationalMode.claim_canary(invocation_id),
             %Issue{} = issue <- canary_issue(),
             %Worker{} = worker <- canary_worker(),
             {:ok, run} <- start_run(worker, issue, invocation_id),
             :ok <- remember_run(run),
             :ok <- OperationalMode.authorize_canary(invocation_id),
             {:ok, analysis} <- adapter.analyze(issue),
             {:ok, proposal} <- Manager.store_analysis(issue, analysis),
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
          OperationalMode.enter_maintenance(actor)
          error
      end
    rescue
      exception ->
        fail_closed({:exception, exception.__struct__}, actor)
    catch
      kind, reason ->
        fail_closed({kind, reason}, actor)
    after
      Process.delete({__MODULE__, :run})
    end
  end

  @doc """
  Replaces a canary whose process is gone: the mode returns to maintenance and
  the abandoned canary's run is closed as failed, so the next canary starts
  clean. Refused when the canary is alive.
  """
  def replace_stale(actor) when is_binary(actor) do
    with {:ok, invocation_id} <- OperationalMode.replace_stale_canary(actor) do
      AgentRun
      |> where(
        [run],
        run.external_key == ^"deployment-canary:#{invocation_id}" and
          run.state in ["starting", "working"]
      )
      |> Repo.all()
      |> Enum.each(&finish_run(&1, "failed", "Read-only deployment canary was abandoned."))

      {:ok, invocation_id}
    end
  end

  @doc "Activates ordinary work after a passed canary, for `opts[:actor]` (default `canary`)."
  def activate(invocation_id, opts \\ []) when is_binary(invocation_id) do
    {actor, opts} = Keyword.pop(opts, :actor, "canary")
    OperationalMode.activate_canary(invocation_id, actor, opts)
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

  defp fail_closed(reason, actor) do
    fail_remembered_run(reason)
    OperationalMode.enter_maintenance(actor)
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
