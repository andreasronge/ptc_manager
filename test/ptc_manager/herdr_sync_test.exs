defmodule PtcManager.HerdrSyncTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Herdr.{Client, Sync}
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentRun, Job, Worker, WorktreeAllocation}
  alias PtcManager.Repo

  defmodule FakeClient do
    @behaviour PtcManager.Herdr
    def list_agents, do: Process.get(:herdr_result)
  end

  test "decodes supported Herdr result envelopes" do
    assert {:ok, [%{"pane_id" => "w1:p1"}]} =
             Client.decode_agents(~s({"result":{"agents":[{"pane_id":"w1:p1"}]}}))

    assert {:error, :invalid_herdr_json} = Client.decode_agents("not json")
  end

  test "reconciles current agents and marks missing activity lost" do
    Process.put(
      :herdr_result,
      {:ok,
       [
         %{
           "agent" => "Codex manager",
           "agent_status" => "working",
           "pane_id" => "w1:p1",
           "workspace_id" => "ptc-manager",
           "agent_session" => %{"value" => "agent-123"}
         }
       ]}
    )

    assert {:ok, %{agent_count: 1, lost_count: 0}} =
             Sync.sync(client: FakeClient, session: "test")

    worker = Repo.get_by!(Worker, worker_key: "herdr:test")
    run = Repo.one!(AgentRun)
    assert worker.status == "online"
    assert run.role == "manager"
    assert run.state == "working"
    assert run.agent_name == "Codex manager"
    assert run.external_key == "test:agent-123"

    Process.put(:herdr_result, {:ok, []})

    assert {:ok, %{agent_count: 0, lost_count: 1}} =
             Sync.sync(client: FakeClient, session: "test")

    lost_run = Repo.get!(AgentRun, run.id)
    assert lost_run.state == "lost"
    assert lost_run.ended_at
  end

  test "preserves terminal history and creates a new attempt when an agent restarts" do
    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")

    Process.put(:herdr_result, {:ok, [remote_agent("done")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")
    finished = Repo.one!(AgentRun)

    Process.put(:herdr_result, {:ok, [remote_agent("done")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")
    assert Repo.get!(AgentRun, finished.id).ended_at == finished.ended_at

    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")
    assert Repo.aggregate(AgentRun, :count) == 2
    assert Repo.one!(from run in AgentRun, where: run.state == "working")
  end

  test "marks stale active agents lost when Herdr cannot be reached" do
    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "outage")

    Process.put(:herdr_result, {:error, :offline})

    assert {:error, {:offline, %{lost_count: 1}}} =
             Sync.sync(client: FakeClient, session: "outage", stale_after_ms: 0)

    assert Repo.one!(AgentRun).state == "lost"
    assert Repo.get_by!(Worker, worker_key: "herdr:outage").status == "degraded"
  end

  test "a managed job becomes reconciling during an outage and resumes when observed again" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:managed-outage"})
    now = now()

    job
    |> Job.changeset(%{
      state: "working",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      lease_expires_at: DateTime.add(now, 60, :second),
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        external_key: "managed-outage:agent-history",
        fencing_token: 1
      })

    Process.put(:herdr_result, {:error, :offline})

    assert {:error, {:offline, %{lost_count: 0, uncertain_count: 1}}} =
             Sync.sync(client: FakeClient, session: "managed-outage", stale_after_ms: 0)

    assert Repo.get!(AgentRun, run.id).state == "unknown"
    assert Repo.get!(Job, job.id).state == "reconciling"
    assert {:error, :already_active} = Operations.approve_issue(issue.id, "andreas")

    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "managed-outage")

    assert Repo.get!(AgentRun, run.id).state == "working"
    assert Repo.get!(Job, job.id).state == "working"
  end

  test "reconciles a lost agent to its later authoritative terminal state" do
    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "recovered")

    Process.put(:herdr_result, {:error, :offline})

    assert {:error, {:offline, %{lost_count: 1}}} =
             Sync.sync(client: FakeClient, session: "recovered", stale_after_ms: 0)

    lost_run = Repo.one!(AgentRun)

    Process.put(:herdr_result, {:ok, [remote_agent("done")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "recovered")

    recovered_run = Repo.get!(AgentRun, lost_run.id)
    assert recovered_run.state == "done"
    assert recovered_run.ended_at == lost_run.ended_at
  end

  test "adopts a positively observed deterministic managed agent" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job
    |> Job.changeset(%{
      state: "reconciling",
      fencing_token: 1,
      lease_owner: "herdr:managed",
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    worker = worker_fixture(%{worker_key: "herdr:managed"})

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "attention",
        path: "/tmp/recovered-worktree",
        last_used_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Process.put(
      :herdr_result,
      {:ok,
       [
         remote_agent("working")
         |> Map.put("name", "impl_j#{job.id}_f1")
         |> Map.put("workspace_id", "recovered-workspace")
         |> Map.put("agent_session", %{"value" => "managed-agent"})
       ]}
    )

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "managed")

    run = Repo.one!(from run in AgentRun, where: run.job_id == ^job.id)
    assert run.fencing_token == 1
    assert Repo.get!(Job, job.id).state == "working"
    recovered_allocation = Repo.get!(WorktreeAllocation, allocation.id)
    assert recovered_allocation.herdr_workspace == "recovered-workspace"
    assert recovered_allocation.state == "active"

    Process.put(
      :herdr_result,
      {:ok,
       [
         remote_agent("done")
         |> Map.put("name", "impl_j#{job.id}_f1")
         |> Map.put("agent_session", %{"value" => "managed-agent"})
       ]}
    )

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "managed")
    completed = Repo.get!(Job, job.id)
    assert completed.state == "awaiting_reconciliation"
    refute completed.ended_at
    refute completed.lease_expires_at
    assert {:error, :already_active} = Operations.approve_issue(issue.id, "andreas")

    second_issue = issue_fixture(repository)
    proposal_fixture(second_issue)
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "andreas")

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:managed",
               %{
                 state: "open",
                 content_digest: second_issue.content_digest,
                 github_updated_at: second_issue.github_updated_at,
                 blocking_issue_numbers: [],
                 dependency_overflow: false
               },
               60_000
             )

    assert Repo.get!(Job, second_job.id).state == "queued"
  end

  test "a successful empty snapshot terminates an old uncertain launch" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job
    |> Job.changeset(%{
      state: "reconciling",
      fencing_token: 1,
      lease_owner: "herdr:absent",
      started_at: DateTime.add(now(), -120, :second),
      reconciling_at: now(),
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    Process.put(:herdr_result, {:ok, []})

    assert {:ok, %{absent_count: 0}} =
             Sync.sync(client: FakeClient, session: "absent", reconcile_after_ms: 60_000)

    refute Repo.get!(Job, job.id).absence_observed_at

    job
    |> Job.changeset(%{reconciling_at: DateTime.add(now(), -61, :second)})
    |> Repo.update!()

    assert {:ok, %{absent_count: 0}} =
             Sync.sync(client: FakeClient, session: "absent", reconcile_after_ms: 60_000)

    first_observation = Repo.get!(Job, job.id)
    assert first_observation.state == "reconciling"
    assert first_observation.absence_observed_at

    assert {:ok, %{absent_count: 1}} =
             Sync.sync(client: FakeClient, session: "absent", reconcile_after_ms: 60_000)

    failed = Repo.get!(Job, job.id)
    assert failed.state == "failed"
    assert failed.ended_at
    assert failed.last_error =~ "no managed agent"
    assert {:ok, _replacement_job} = Operations.approve_issue(issue.id, "andreas")
  end

  test "does not adopt a managed identity from a different Herdr session" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job
    |> Job.changeset(%{
      state: "reconciling",
      fencing_token: 1,
      lease_owner: "herdr:expected",
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    Process.put(
      :herdr_result,
      {:ok, [remote_agent("working") |> Map.put("name", "impl_j#{job.id}_f1")]}
    )

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "impostor")
    assert Repo.one!(AgentRun).job_id == nil
    assert Repo.get!(Job, job.id).state == "reconciling"
  end

  test "a restarted terminal managed identity requires two absent snapshots to release" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:restart"})
    now = now()

    job
    |> Job.changeset(%{
      state: "awaiting_reconciliation",
      fencing_token: 1,
      lease_owner: "herdr:restart",
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    {:ok, terminal_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "done",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        ended_at: now,
        external_key: "restart:agent-history",
        fencing_token: 1
      })

    Process.put(
      :herdr_result,
      {:ok,
       [
         remote_agent("working")
         |> Map.put("name", "impl_j#{job.id}_f1")
         |> Map.put("agent_session", %{"value" => "replacement-agent-session"})
       ]}
    )

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "restart")
    assert Repo.get!(AgentRun, terminal_run.id).state == "done"
    assert Repo.get!(Job, job.id).state == "reconciling"
    assert Repo.aggregate(from(run in AgentRun, where: run.job_id == ^job.id), :count) == 1

    Process.put(:herdr_result, {:ok, []})

    assert {:ok, %{absent_count: 0}} =
             Sync.sync(client: FakeClient, session: "restart", reconcile_after_ms: 0)

    assert Repo.get!(Job, job.id).state == "reconciling"

    assert {:ok, %{absent_count: 1}} =
             Sync.sync(client: FakeClient, session: "restart", reconcile_after_ms: 0)

    assert Repo.get!(Job, job.id).state == "failed"
  end

  defp remote_agent(state) do
    %{
      "agent" => "Codex implementer",
      "agent_status" => state,
      "pane_id" => "w1:p1",
      "agent_session" => %{"value" => "agent-history"}
    }
  end
end
