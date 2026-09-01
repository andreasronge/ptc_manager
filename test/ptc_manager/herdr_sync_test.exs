defmodule PtcManager.HerdrSyncTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Herdr.{Client, Sync}
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AgentRun, Job, Worker, WorktreeAllocation}
  alias PtcManager.Repo
  alias PtcManager.RuntimeIncarnation

  defmodule FakeClient do
    @behaviour PtcManager.Herdr
    def list_agents, do: Process.get(:herdr_result)
  end

  defmodule PausedClient do
    @behaviour PtcManager.Herdr

    def list_agents do
      test_pid = Application.fetch_env!(:ptc_manager, :paused_herdr_test_pid)
      send(test_pid, {:herdr_snapshot_requested, self()})

      receive do
        {:return_herdr_snapshot, result} -> result
      end
    end
  end

  test "decodes supported Herdr result envelopes" do
    assert {:ok, [%{"pane_id" => "w1:p1"}]} =
             Client.decode_agents(~s({"result":{"agents":[{"pane_id":"w1:p1"}]}}))

    assert {:error, :invalid_herdr_json} = Client.decode_agents("not json")
  end

  test "decodes authoritative Herdr snapshot identity when present" do
    output =
      Jason.encode!(%{
        "result" => %{
          "agents" => [%{"pane_id" => "w1:p1"}],
          "worker_incarnation_id" => "worker-boot-2",
          "herdr_incarnation_id" => "herdr-boot-7",
          "snapshot_sequence" => 14,
          "restart_reason" => "service restart"
        }
      })

    assert {:ok,
            %{
              agents: [%{"pane_id" => "w1:p1"}],
              worker_incarnation_id: "worker-boot-2",
              herdr_incarnation_id: "herdr-boot-7",
              snapshot_sequence: 14,
              restart_reason: "service restart"
            }} = Client.decode_snapshot(output)
  end

  test "an identityless snapshot cannot downgrade an enrolled worker" do
    Process.put(
      :herdr_result,
      {:ok,
       %{
         agents: [],
         worker_incarnation_id: "worker-boot-1",
         herdr_incarnation_id: "herdr-boot-1",
         snapshot_sequence: 1
       }}
    )

    assert {:ok, %{agent_count: 0}} = Sync.sync(client: FakeClient, session: "enrolled")
    assert Repo.get_by!(Worker, worker_key: "herdr:enrolled").status == "online"

    Process.put(:herdr_result, {:ok, []})

    assert {:ok, %{recovery_pending: true}} =
             Sync.sync(client: FakeClient, session: "enrolled")

    worker = Repo.get_by!(Worker, worker_key: "herdr:enrolled")
    assert worker.status == "degraded"
    assert worker.healthy_snapshot_count == 0
    assert is_nil(worker.coordinator_incarnation_id)
  end

  test "a fresh coordinator fences a legacy worker until it observes a snapshot" do
    worker =
      worker_fixture(%{
        worker_key: "herdr:legacy-admission",
        capabilities: %{"herdr" => true, "implementation_slots" => 1},
        coordinator_incarnation_id: nil
      })

    assert {:error, :worker_unavailable} = Operations.dispatch_capacity(worker.worker_key)

    Process.put(:herdr_result, {:ok, []})
    assert {:ok, %{agent_count: 0}} = Sync.sync(client: FakeClient, session: "legacy-admission")

    admitted = Repo.get!(Worker, worker.id)
    assert admitted.coordinator_incarnation_id == RuntimeIncarnation.current()
    assert {:ok, 1} = Operations.dispatch_capacity(worker.worker_key)
  end

  test "an incarnation change quarantines and then re-adopts a Herdr repair action" do
    %{action: action, remote: remote_agent, run: run, worker: worker} =
      active_repair_run_fixture("action-restart", %{
        worker_incarnation_id: "worker-boot-1",
        herdr_incarnation_id: "herdr-boot-1",
        snapshot_sequence: 8,
        healthy_snapshot_count: 2,
        coordinator_incarnation_id: RuntimeIncarnation.current()
      })

    Process.put(
      :herdr_result,
      {:ok,
       %{
         agents: [remote_agent],
         worker_incarnation_id: "worker-boot-2",
         herdr_incarnation_id: "herdr-boot-2",
         snapshot_sequence: 1,
         restart_reason: "Herdr service restart"
       }}
    )

    assert {:ok, %{recovery_pending: true, uncertain_count: 1}} =
             Sync.sync(client: FakeClient, session: "action-restart")

    assert Repo.get!(AgentRun, run.id).state == "unknown"
    assert Repo.get!(AgentAction, action.id).state == "running"
    assert Repo.get!(Worker, worker.id).status == "degraded"

    Process.put(
      :herdr_result,
      {:ok,
       %{
         agents: [remote_agent],
         worker_incarnation_id: "worker-boot-2",
         herdr_incarnation_id: "herdr-boot-2",
         snapshot_sequence: 2
       }}
    )

    assert {:ok, %{agent_count: 1}} = Sync.sync(client: FakeClient, session: "action-restart")
    assert Repo.get!(AgentRun, run.id).state == "working"
    assert Repo.get!(AgentAction, action.id).state == "running"
  end

  test "transport recovery retains and re-adopts a Herdr repair action run" do
    %{action: action, remote: remote_agent, run: run} =
      active_repair_run_fixture("action-outage")

    Process.put(:herdr_result, {:error, :offline})

    assert {:error, {:offline, %{lost_count: 0, uncertain_count: 1}}} =
             Sync.sync(client: FakeClient, session: "action-outage", stale_after_ms: 0)

    assert Repo.get!(AgentRun, run.id).state == "unknown"
    assert Repo.get!(AgentAction, action.id).state == "running"

    Process.put(:herdr_result, {:ok, [remote_agent]})
    assert {:ok, %{agent_count: 1}} = Sync.sync(client: FakeClient, session: "action-outage")

    assert Repo.get!(AgentRun, run.id).state == "working"
    assert Repo.get!(AgentAction, action.id).state == "running"
    assert Repo.aggregate(AgentRun, :count) == 1
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

  test "binds the final Herdr session identity to its action run and hides startup duplicates" do
    repository = repository_fixture()
    worker = worker_fixture(%{worker_key: "herdr:action-dedupe"})
    now = now()

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: 1704,
        target_label: "example/repo#1704",
        prompt_version: 1,
        prompt: "Fix and merge PR 1704",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "running",
        attempt_count: 1,
        requested_at: now,
        started_at: now
      })
      |> Repo.insert!()

    {:ok, action_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "working",
        agent_name: "merge_pr1704_a#{action.id}_f1",
        started_at: now,
        last_heartbeat_at: now,
        herdr_workspace: "w7",
        herdr_pane: "w7:p1",
        herdr_session: "action-dedupe",
        external_key: "action-dedupe:w7:p1",
        fencing_token: 1
      })

    {:ok, duplicate} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "implementer",
        state: "working",
        agent_name: "merge_pr1704_a#{action.id}_f1",
        started_at: now,
        last_heartbeat_at: now,
        herdr_workspace: "w7",
        herdr_pane: "w7:p1",
        herdr_session: "action-dedupe",
        external_key: "action-dedupe:old-pane-identity"
      })

    Process.put(
      :herdr_result,
      {:ok,
       [
         %{
           "agent" => "codex",
           "name" => "merge_pr1704_a#{action.id}_f1",
           "agent_status" => "working",
           "pane_id" => "w7:p1",
           "workspace_id" => "w7",
           "agent_session" => %{"value" => "final-session"}
         }
       ]}
    )

    assert {:ok, %{agent_count: 1}} =
             Sync.sync(client: FakeClient, session: "action-dedupe")

    rebound = Repo.get!(AgentRun, action_run.id)
    assert rebound.state == "working"
    assert rebound.external_key == "action-dedupe:final-session"

    superseded = Repo.get!(AgentRun, duplicate.id)
    assert superseded.state == "lost"
    assert superseded.status_text == "Superseded duplicate of the action-owned Herdr run."
    assert Enum.map(Operations.list_active_agent_runs(), & &1.id) == [action_run.id]
    assert Enum.map(Operations.list_agent_timeline(), & &1.id) == [action_run.id]
  end

  test "an early idle snapshot preserves an unattached action run in starting state" do
    repository = repository_fixture()
    worker = worker_fixture(%{worker_key: "herdr:early-action-snapshot"})
    now = now()

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_pr",
        target_type: "pull_request",
        target_id: 1705,
        target_label: "example/repo#1705",
        prompt_version: 1,
        prompt: "Fix PR 1705",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "running",
        attempt_count: 1,
        requested_at: now,
        started_at: now
      })
      |> Repo.insert!()

    {:ok, action_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "starting",
        status_text: "Waiting for Herdr to create the pull-request repair session.",
        started_at: now,
        last_heartbeat_at: now,
        fencing_token: 1
      })

    Process.put(
      :herdr_result,
      {:ok,
       [
         %{
           "agent" => "codex",
           "name" => "repair_pr1705_a#{action.id}_f1",
           "agent_status" => "idle",
           "pane_id" => "w8:p1",
           "workspace_id" => "w8",
           "agent_session" => %{"value" => "early-final-session"}
         }
       ]}
    )

    assert {:ok, %{agent_count: 1}} =
             Sync.sync(client: FakeClient, session: "early-action-snapshot")

    assert {:ok, %{agent_count: 1}} =
             Sync.sync(client: FakeClient, session: "early-action-snapshot")

    rebound = Repo.get!(AgentRun, action_run.id)
    assert rebound.state == "starting"
    assert rebound.external_key == "early-action-snapshot:early-final-session"
    assert Repo.aggregate(AgentRun, :count) == 1
  end

  test "operations hides an orphan action duplicate even after Herdr has already stopped" do
    repository = repository_fixture()
    worker = worker_fixture(%{worker_key: "herdr:stopped-action-dedupe"})
    now = now()

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: 1704,
        target_label: "example/repo#1704",
        prompt_version: 1,
        prompt: "Fix and merge PR 1704",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "done",
        attempt_count: 1,
        requested_at: now,
        started_at: now,
        ended_at: now
      })
      |> Repo.insert!()

    {:ok, retained} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "done",
        agent_name: "merge_pr1704_a#{action.id}_f1",
        started_at: now,
        last_heartbeat_at: now,
        ended_at: now,
        fencing_token: 1
      })

    {:ok, _orphan} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "implementer",
        state: "lost",
        agent_name: retained.agent_name,
        started_at: now,
        last_heartbeat_at: now,
        ended_at: now,
        external_key: "stopped-action-dedupe:old-session"
      })

    assert Enum.map(Operations.list_recent_agent_runs(), & &1.id) == [retained.id]
    assert Enum.map(Operations.list_agent_timeline(), & &1.id) == [retained.id]
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

    assert {:ok, leased_second_job} =
             Operations.lease_job(
               second_job.id,
               "herdr:managed",
               %{
                 state: "open",
                 content_digest: second_issue.content_digest,
                 github_updated_at: second_issue.github_updated_at,
                 blocking_issues: [],
                 dependency_overflow: false
               },
               60_000
             )

    assert leased_second_job.state == "starting"
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

  test "an open PR keeps its terminal Herdr agent waiting and resumes the same run" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:retained"})
    now = now()

    job =
      job
      |> Job.changeset(%{
        state: "pr_open",
        fencing_token: 1,
        lease_owner: worker.worker_key,
        branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
      })
      |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "waiting",
        path: "/tmp/retained-worktree",
        herdr_workspace: "retained-workspace",
        last_used_at: now
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "done",
        agent_name: "impl_j#{job.id}_f1",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        ended_at: now,
        external_key: "retained:agent-history",
        fencing_token: 1
      })

    retained_remote =
      remote_agent("done")
      |> Map.put("name", run.agent_name)
      |> Map.put("workspace_id", "retained-workspace")

    Process.put(:herdr_result, {:ok, [retained_remote]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "retained")

    waiting = Repo.get!(AgentRun, run.id)
    assert waiting.state == "waiting"
    refute waiting.ended_at
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "waiting"

    Process.put(:herdr_result, {:ok, [Map.put(retained_remote, "agent_status", "working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "retained")

    resumed = Repo.get!(AgentRun, run.id)
    assert resumed.state == "working"

    assert Repo.aggregate(from(candidate in AgentRun, where: candidate.job_id == ^job.id), :count) ==
             1

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "active"

    allocation
    |> WorktreeAllocation.changeset(%{state: "waiting"})
    |> Repo.update!()

    Process.put(:herdr_result, {:ok, [Map.put(retained_remote, "agent_status", "blocked")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "retained")

    assert Repo.get!(AgentRun, run.id).state == "blocked"
    blocked_allocation = Repo.get!(WorktreeAllocation, allocation.id) |> Repo.preload(:job)
    assert blocked_allocation.state == "waiting"
    refute Operations.worktree_consumes_execution_slot?(blocked_allocation)

    blocked_allocation
    |> WorktreeAllocation.changeset(%{state: "active"})
    |> Repo.update!()

    Process.put(:herdr_result, {:ok, [Map.put(retained_remote, "agent_status", "failed")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "retained")

    failed_allocation = Repo.get!(WorktreeAllocation, allocation.id) |> Repo.preload(:job)
    assert Repo.get!(AgentRun, run.id).state == "failed"
    assert failed_allocation.state == "attention"
    assert failed_allocation.last_error =~ "ended in state failed"
    refute Operations.worktree_consumes_execution_slot?(failed_allocation)
  end

  test "a snapshot started before repair resumption cannot overwrite the resumed slot" do
    Application.put_env(:ptc_manager, :paused_herdr_test_pid, self())
    on_exit(fn -> Application.delete_env(:ptc_manager, :paused_herdr_test_pid) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:stale-snapshot"})
    now = now()

    job
    |> Job.changeset(%{
      state: "pr_open",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "waiting",
        path: "/tmp/stale-snapshot-worktree",
        herdr_workspace: "stale-snapshot-workspace",
        last_used_at: now
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "waiting",
        agent_name: "impl_j#{job.id}_f1",
        herdr_workspace: "stale-snapshot-workspace",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        external_key: "stale-snapshot:agent-history",
        fencing_token: 1
      })

    sync_task = Task.async(fn -> Sync.sync(client: PausedClient, session: "stale-snapshot") end)
    assert_receive {:herdr_snapshot_requested, snapshot_pid}
    Process.sleep(2)
    resumed_at = now()

    run
    |> AgentRun.changeset(%{
      state: "working",
      last_heartbeat_at: resumed_at,
      ended_at: nil
    })
    |> Repo.update!()

    allocation
    |> WorktreeAllocation.changeset(%{state: "active", last_used_at: resumed_at})
    |> Repo.update!()

    send(snapshot_pid, {:return_herdr_snapshot, {:ok, []}})
    assert {:ok, _summary} = Task.await(sync_task)

    assert Repo.get!(AgentRun, run.id).state == "working"
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "active"
  end

  test "a successful empty snapshot releases an uncertain retained repair slot to attention" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:missing-retained"})
    now = now()

    job
    |> Job.changeset(%{
      state: "pr_open",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "active",
        path: "/tmp/missing-retained-worktree",
        herdr_workspace: "missing-retained-workspace",
        last_used_at: now
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "unknown",
        agent_name: "impl_j#{job.id}_f1",
        herdr_workspace: "missing-retained-workspace",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        external_key: "missing-retained:agent-history",
        fencing_token: 1
      })

    Process.put(:herdr_result, {:ok, []})
    assert {:ok, %{lost_count: 1}} = Sync.sync(client: FakeClient, session: "missing-retained")

    assert Repo.get!(AgentRun, run.id).state == "lost"
    released = Repo.get!(WorktreeAllocation, allocation.id)
    assert released.state == "attention"
    assert released.last_error =~ "no longer present"
    refute Operations.worktree_consumes_execution_slot?(%{released | job: Repo.get!(Job, job.id)})

    remote =
      remote_agent("working")
      |> Map.put("name", run.agent_name)
      |> Map.put("workspace_id", "missing-retained-workspace")

    Process.put(:herdr_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "missing-retained")

    assert Repo.get!(AgentRun, run.id).state == "working"
    reacquired = Repo.get!(WorktreeAllocation, allocation.id) |> Repo.preload(:job)
    assert reacquired.state == "active"
    assert Operations.worktree_consumes_execution_slot?(reacquired)
  end

  test "a repeated retained snapshot does not erase worktree attention" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:attention-retained"})
    now = now()

    job
    |> Job.changeset(%{
      state: "pr_open",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    })
    |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "attention",
        path: "/tmp/attention-retained-worktree",
        herdr_workspace: "attention-retained-workspace",
        last_used_at: now,
        last_error: "Repair verification found untracked files."
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "waiting",
        agent_name: "impl_j#{job.id}_f1",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        external_key: "attention-retained:agent-history",
        fencing_token: 1
      })

    remote = remote_agent("done") |> Map.put("name", run.agent_name)
    Process.put(:herdr_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "attention-retained")

    preserved = Repo.get!(WorktreeAllocation, allocation.id)
    assert preserved.state == "attention"
    assert preserved.last_error == "Repair verification found untracked files."

    Repo.get!(AgentRun, run.id)
    |> AgentRun.changeset(%{state: "lost", ended_at: now})
    |> Repo.update!()

    remote =
      remote_agent("working")
      |> Map.put("name", run.agent_name)
      |> Map.put("workspace_id", "attention-retained-workspace")

    Process.put(:herdr_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "attention-retained")

    preserved = Repo.get!(WorktreeAllocation, allocation.id) |> Repo.preload(job: :agent_runs)
    assert Repo.get!(AgentRun, run.id).state == "working"
    assert preserved.state == "attention"
    assert preserved.last_error == "Repair verification found untracked files."
    assert Operations.worktree_consumes_execution_slot?(preserved)

    Process.put(:herdr_result, {:ok, [Map.put(remote, "agent_status", "failed")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "attention-retained")

    preserved = Repo.get!(WorktreeAllocation, allocation.id)
    assert Repo.get!(AgentRun, run.id).state == "failed"
    assert preserved.state == "attention"
    assert preserved.last_error == "Repair verification found untracked files."
  end

  test "an idle snapshot cannot reactivate a terminal merged-PR worktree" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:terminal"})
    now = now()

    job =
      job
      |> Job.changeset(%{
        state: "done",
        ended_at: now,
        fencing_token: 1,
        lease_owner: worker.worker_key,
        branch_name: "ptc/merged"
      })
      |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "terminal",
        path: "/tmp/terminal-worktree",
        herdr_workspace: "terminal-workspace",
        last_used_at: now
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "done",
        agent_name: "impl_j#{job.id}_f1",
        herdr_workspace: "terminal-workspace",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        ended_at: now,
        external_key: "terminal:agent-history",
        fencing_token: 1
      })

    remote =
      remote_agent("idle")
      |> Map.put("name", run.agent_name)
      |> Map.put("workspace_id", "terminal-workspace")

    Process.put(:herdr_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "terminal")

    assert Repo.get!(AgentRun, run.id).state == "done"
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "terminal"
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

  defp active_repair_run_fixture(session, worker_attrs \\ %{}) do
    repository = repository_fixture()

    worker =
      worker_fixture(
        Map.merge(
          %{
            worker_key: "herdr:#{session}",
            capabilities: %{"herdr" => true, "implementation_slots" => 1}
          },
          worker_attrs
        )
      )

    now = now()

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: 1_704,
        target_label: "example/repo#1704",
        prompt_version: 1,
        prompt: "Repair and merge PR 1704",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "running",
        attempt_count: 1,
        requested_at: now,
        started_at: now
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "working",
        agent_name: "merge_pr1704_a#{action.id}_f1",
        started_at: now,
        last_heartbeat_at: now,
        herdr_workspace: "repair-workspace",
        herdr_pane: "repair-workspace:p1",
        herdr_session: session,
        external_key: "#{session}:repair-session",
        fencing_token: 1
      })

    remote = %{
      "name" => run.agent_name,
      "agent_status" => "working",
      "workspace_id" => "repair-workspace",
      "pane_id" => "repair-workspace:p1",
      "agent_session" => %{"value" => "repair-session"}
    }

    %{action: action, remote: remote, run: run, worker: worker}
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
