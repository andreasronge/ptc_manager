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

    @impl true
    def list_agents, do: Process.get(:herdr_result)

    @impl true
    def close_pane(_pane_id), do: :ok
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

  test "a stale unknown record of a finished action is marked lost" do
    %{action: action, run: run, worker: worker} = active_repair_run_fixture("stale-record")
    action |> AgentAction.changeset(%{state: "done", ended_at: now()}) |> Repo.update!()

    # The repair ran in a job's retained implementer, so the record carries that
    # agent's name and no Herdr identity of its own; an outage marked it unknown.
    run
    |> AgentRun.changeset(%{state: "unknown", agent_name: "impl_j25_f1", external_key: nil})
    |> Repo.update!()

    Process.put(:herdr_result, {:ok, []})
    assert {:ok, %{lost_count: 1}} = Sync.sync(client: FakeClient, session: "stale-record")

    lost = Repo.get!(AgentRun, run.id)
    assert lost.state == "lost"
    assert lost.ended_at
    assert lost.status_text =~ "no Herdr agent remains"
    assert Repo.get!(AgentAction, action.id).state == "done"
    assert Repo.get!(Worker, worker.id).status == "online"
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

  # Every snapshot rewrites the same blocked state and refreshes the heartbeat,
  # so an agent parked at a question nobody answers looks as fresh on its
  # thirtieth hour as on its first. Only the moment the state last changed can
  # tell them apart, and repeated snapshots must not move it.
  test "a pane that outlives a cancelled agent cannot resurrect its run" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    worker =
      worker_fixture(%{
        worker_key: "herdr:cancelled",
        capabilities: %{"herdr" => true, "implementation_slots" => 1}
      })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    job =
      job
      |> Job.changeset(%{
        state: "working",
        fencing_token: 1,
        lease_owner: worker.worker_key,
        lease_expires_at: DateTime.add(now, 600, :second),
        started_at: now,
        branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
      })
      |> Repo.update!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        agent_name: "impl_j#{job.id}_f1",
        started_at: now,
        last_heartbeat_at: now,
        herdr_workspace: "ptc-cancelled",
        herdr_pane: "w9:p1",
        herdr_session: "cancelled",
        external_key: "cancelled:agent-cancel",
        fencing_token: 1
      })

    previous = Application.get_env(:ptc_manager, :herdr_client)
    Application.put_env(:ptc_manager, :herdr_client, FakeClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :herdr_client, previous) end)

    assert {:ok, _cancelled} = Operations.cancel_running_job(job.id, "andreas")

    Process.put(
      :herdr_result,
      {:ok,
       [
         %{
           "agent" => "impl_j#{job.id}_f1",
           "agent_status" => "working",
           "pane_id" => "w9:p1",
           "workspace_id" => "ptc-cancelled",
           "agent_session" => %{"value" => "agent-cancel"}
         }
       ]}
    )

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "cancelled")

    assert Repo.get!(AgentRun, run.id).state == "lost"
    assert Repo.get!(Job, job.id).state == "cancelled"
  end

  test "records when a run entered its state and holds it across repeated snapshots" do
    blocked = fn ->
      {:ok,
       [
         %{
           "agent" => "Codex manager",
           "agent_status" => "blocked",
           "pane_id" => "w1:p1",
           "workspace_id" => "ptc-manager",
           "agent_session" => %{"value" => "agent-blocked"}
         }
       ]}
    end

    Process.put(:herdr_result, blocked.())
    assert {:ok, %{agent_count: 1}} = Sync.sync(client: FakeClient, session: "state-age")

    run = Repo.one!(from run in AgentRun, where: run.external_key == "state-age:agent-blocked")
    assert run.state == "blocked"
    assert run.state_changed_at

    Process.put(:herdr_result, blocked.())
    assert {:ok, %{agent_count: 1}} = Sync.sync(client: FakeClient, session: "state-age")

    unchanged = Repo.get!(AgentRun, run.id)
    assert unchanged.state_changed_at == run.state_changed_at
    assert DateTime.compare(unchanged.last_heartbeat_at, run.last_heartbeat_at) != :lt

    Process.put(
      :herdr_result,
      {:ok,
       [
         %{
           "agent" => "Codex manager",
           "agent_status" => "working",
           "pane_id" => "w1:p1",
           "workspace_id" => "ptc-manager",
           "agent_session" => %{"value" => "agent-blocked"}
         }
       ]}
    )

    assert {:ok, %{agent_count: 1}} = Sync.sync(client: FakeClient, session: "state-age")

    resumed = Repo.get!(AgentRun, run.id)
    assert resumed.state == "working"
    assert DateTime.compare(resumed.state_changed_at, run.state_changed_at) == :gt
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
    %{issue: issue, job: job, run: run} = managed_job_fixture("managed-outage")

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

  test "an idle managed agent gets one bounded deadline instead of renewing forever" do
    previous_timeout = Application.get_env(:ptc_manager, :implementation_idle_timeout_ms)
    Application.put_env(:ptc_manager, :implementation_idle_timeout_ms, 5_000)

    on_exit(fn ->
      if previous_timeout,
        do: Application.put_env(:ptc_manager, :implementation_idle_timeout_ms, previous_timeout),
        else: Application.delete_env(:ptc_manager, :implementation_idle_timeout_ms)
    end)

    %{job: job, run: run} =
      managed_job_fixture("idle-deadline", %{agent_name: :deterministic})

    remote = remote_agent("idle") |> Map.put("name", run.agent_name)
    Process.put(:herdr_result, {:ok, [remote]})

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "idle-deadline")
    first_deadline = Repo.get!(Job, job.id).lease_expires_at
    assert Repo.get!(AgentRun, run.id).state == "idle"

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "idle-deadline")
    assert Repo.get!(Job, job.id).lease_expires_at == first_deadline
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

  test "a continued agent keeps the same job and run after its session identity changes" do
    %{job: job, run: run} = managed_job_fixture("review-resume", %{agent_name: :deterministic})
    name = "impl_j#{job.id}_f1_r1"

    job
    |> Job.changeset(%{
      review_generation: 1,
      review_state: "changes_requested",
      state: "reconciling"
    })
    |> Repo.update!()

    run |> AgentRun.changeset(%{agent_name: name}) |> Repo.update!()

    Process.put(
      :herdr_result,
      {:ok,
       [
         remote_agent("working")
         |> Map.put("name", name)
         |> Map.put("agent_session", %{"value" => "resumed-session"})
       ]}
    )

    assert {:ok, _} = Sync.sync(client: FakeClient, session: "review-resume")
    assert Repo.get!(Job, job.id).state == "working"
    assert Repo.get!(AgentRun, run.id).agent_name == name
    assert Repo.aggregate(from(r in AgentRun, where: r.job_id == ^job.id), :count) == 1
  end

  test "missing agents do not terminalize jobs held for review decisions" do
    %{job: job} = managed_job_fixture("review-held", %{agent_name: :deterministic})

    for state <- ~w(paused running manual resume_pending) do
      job
      |> Job.changeset(%{
        state: "reconciling",
        review_state: state,
        reconciling_at: DateTime.add(now(), -120, :second),
        absence_observed_at: DateTime.add(now(), -60, :second)
      })
      |> Repo.update!()

      Process.put(:herdr_result, {:ok, []})

      assert {:ok, %{absent_count: 0}} =
               Sync.sync(client: FakeClient, session: "review-held", reconcile_after_ms: 0)

      assert Repo.get!(Job, job.id).state not in ~w(failed lost cancelled)
      assert Repo.get!(Job, job.id).review_state == state
    end
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
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}",
      last_error: "{:agent_launch_after_workspace_setup, :herdr_timeout}"
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

    assert failed.last_error =~
             "Earlier error: {:agent_launch_after_workspace_setup, :herdr_timeout}"

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

  test "a repair resumed in a retained session follows the pane it shares with the job's run" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:shared-pane"})
    now = now()
    earlier = DateTime.add(now, -900, :second)

    job
    |> Job.changeset(%{state: "pr_open", fencing_token: 1, lease_owner: worker.worker_key})
    |> Repo.update!()

    # What RetainedHerdrAdapter.mark_resumed/2 leaves behind: the job's run
    # is working again, and the action's run carries the retained session's
    # identity in starting, with a heartbeat that has not moved since.
    {:ok, job_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        agent_name: "impl_j#{job.id}_f1",
        herdr_workspace: "shared-workspace",
        herdr_pane: "w4:p1",
        herdr_session: "shared-pane",
        started_at: earlier,
        last_heartbeat_at: earlier,
        external_key: "shared-pane:agent-shared",
        fencing_token: 1
      })

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_pr",
        target_type: "pull_request",
        target_id: 1,
        target_label: "example/repo#1",
        prompt_version: 1,
        prompt: "Repair PR 1",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "running",
        attempt_count: 1,
        requested_at: earlier,
        started_at: earlier
      })
      |> Repo.insert!()

    {:ok, action_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "starting",
        agent_name: "impl_j#{job.id}_f1",
        herdr_workspace: "shared-workspace",
        herdr_pane: "w4:p1",
        herdr_session: "shared-pane",
        started_at: earlier,
        last_heartbeat_at: earlier,
        fencing_token: 1
      })

    pane = %{
      "agent" => "impl_j#{job.id}_f1",
      "agent_status" => "idle",
      "pane_id" => "w4:p1",
      "workspace_id" => "shared-workspace",
      "agent_session" => %{"value" => "agent-shared"}
    }

    # The prompt has not been picked up yet: the retained pane is still idle,
    # which the job's pr_open state reads as waiting. The action's run is not
    # parked; it keeps its heartbeat and waits for the pane to execute.
    Process.put(:herdr_result, {:ok, [pane]})
    assert {:ok, %{lost_count: 0}} = Sync.sync(client: FakeClient, session: "shared-pane")
    idle_action_run = Repo.get!(AgentRun, action_run.id)
    assert idle_action_run.state == "starting"
    assert DateTime.compare(idle_action_run.last_heartbeat_at, earlier) == :gt

    Process.put(:herdr_result, {:ok, [%{pane | "agent_status" => "working"}]})
    assert {:ok, %{lost_count: 0}} = Sync.sync(client: FakeClient, session: "shared-pane")

    assert Repo.get!(AgentRun, job_run.id).state == "working"
    refreshed_action_run = Repo.get!(AgentRun, action_run.id)
    assert refreshed_action_run.state == "working"
    assert Repo.get!(AgentAction, action.id).state == "running"

    assert %{status: :healthy} =
             PtcManager.Operations.AgentHealth.assess(refreshed_action_run, now())

    # An outage marked the action's run unknown; the next observation of the
    # executing pane recovers it, as it does the job's run.
    action_run |> AgentRun.changeset(%{state: "unknown"}) |> Repo.update!()
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "shared-pane")
    assert Repo.get!(AgentRun, action_run.id).state == "working"
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

    worker =
      worker_fixture(%{
        worker_key: "herdr:missing-retained",
        worker_incarnation_id: "terminal-worker",
        herdr_incarnation_id: "terminal-herdr",
        snapshot_sequence: 1,
        healthy_snapshot_count: 2,
        coordinator_incarnation_id: RuntimeIncarnation.current()
      })

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

    Process.put(:herdr_result, {:ok, authoritative_snapshot([], 2)})
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

    Process.put(:herdr_result, {:ok, authoritative_snapshot([remote], 3)})

    assert_no_transaction_reads(fn ->
      assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "missing-retained")
    end)

    assert Repo.get!(AgentRun, run.id).state == "working"
    reacquired = Repo.get!(WorktreeAllocation, allocation.id) |> Repo.preload(:job)
    assert reacquired.state == "active"
    assert Operations.worktree_consumes_execution_slot?(reacquired)
  end

  test "a settled identityless snapshot uses a write-only transaction" do
    %{run: run, worker: worker} =
      managed_job_fixture("identityless-steady", %{
        agent_name: :deterministic,
        state: "done",
        ended_at: now()
      })

    remote = remote_agent("done") |> Map.put("name", run.agent_name)
    Process.put(:herdr_result, {:ok, [remote]})

    assert_no_transaction_reads(fn ->
      assert {:ok, %{lost_count: 0}} =
               Sync.sync(client: FakeClient, session: "identityless-steady")
    end)

    refreshed_worker = Repo.get!(Worker, worker.id)
    assert refreshed_worker.snapshot_sequence == 0
    assert refreshed_worker.healthy_snapshot_count == 0
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

    worker =
      worker_fixture(%{
        worker_key: "herdr:terminal",
        worker_incarnation_id: "terminal-worker",
        herdr_incarnation_id: "terminal-herdr",
        snapshot_sequence: 1,
        healthy_snapshot_count: 2,
        coordinator_incarnation_id: RuntimeIncarnation.current()
      })

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

    Process.put(:herdr_result, {:ok, authoritative_snapshot([remote], 2)})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "terminal")

    assert Repo.get!(AgentRun, run.id).state == "done"
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "terminal"

    handler = "settled-terminal-worktree-writes-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_manager, :repo, :query],
        fn event, measurements, metadata, {pid, _transaction_key} = config ->
          track_transaction_reads(event, measurements, metadata, config)
          query = to_string(metadata[:query])

          cond do
            metadata[:source] == "worktree_allocations" and
                String.starts_with?(query, "UPDATE") ->
              send(pid, {:worktree_write, query})

            metadata[:source] == "jobs" and String.starts_with?(query, "SELECT") ->
              send(pid, :job_read)

            true ->
              :ok
          end
        end,
        {test_pid, {__MODULE__, handler, :transaction}}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    settled_remote = Map.put(remote, "agent_status", "done")
    Process.put(:herdr_result, {:ok, authoritative_snapshot([settled_remote], 3)})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "terminal")
    refute_receive {:worktree_write, _query}
    refute_receive {:transaction_read, _source}
    assert_receive :job_read
    refute_receive :job_read
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

  test "a restored idle pane for a finished retained agent does not re-park a paused job" do
    %{job: job, run: run} =
      managed_job_fixture("restored-idle", %{
        agent_name: :deterministic,
        state: "done",
        ended_at: now()
      })

    job
    |> Job.changeset(%{state: "blocked", review_state: "paused", lease_expires_at: nil})
    |> Repo.update!()

    for observed <- ~w(idle done unknown) do
      Process.put(
        :herdr_result,
        {:ok, [remote_agent(observed) |> Map.put("name", run.agent_name)]}
      )

      assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "restored-idle")
      assert Repo.get!(Job, job.id).state == "blocked"
      assert Repo.get!(AgentRun, run.id).state == "done"
    end

    Process.put(
      :herdr_result,
      {:ok, [remote_agent("working") |> Map.put("name", run.agent_name)]}
    )

    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "restored-idle")
    assert Repo.get!(Job, job.id).state == "reconciling"
  end

  test "a terminal pane settles its active owner after briefly reporting working" do
    %{job: job, run: run, worker: worker} =
      managed_job_fixture("terminal-reactivation", %{
        agent_name: :deterministic,
        state: "done",
        ended_at: now()
      })

    worker
    |> Worker.changeset(%{
      worker_incarnation_id: "terminal-worker",
      herdr_incarnation_id: "terminal-herdr",
      snapshot_sequence: 1,
      healthy_snapshot_count: 2,
      coordinator_incarnation_id: RuntimeIncarnation.current()
    })
    |> Repo.update!()

    working = remote_agent("working") |> Map.put("name", run.agent_name)
    Process.put(:herdr_result, {:ok, authoritative_snapshot([working], 2)})

    assert_no_transaction_reads(fn ->
      assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "terminal-reactivation")
    end)

    assert Repo.get!(Job, job.id).state == "reconciling"

    done = remote_agent("done") |> Map.put("name", run.agent_name)
    Process.put(:herdr_result, {:ok, authoritative_snapshot([done], 3)})

    assert_no_transaction_reads(fn ->
      assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "terminal-reactivation")
    end)

    assert Repo.get!(Job, job.id).state == "awaiting_reconciliation"
  end

  test "a held job parked in reconciling settles back to blocked once its agent is not active" do
    %{job: job, run: run} =
      managed_job_fixture("held-settle", %{
        agent_name: :deterministic,
        state: "done",
        ended_at: now()
      })

    idle = remote_agent("idle") |> Map.put("name", run.agent_name)

    for {observed, review_state} <- [{[], "paused"}, {[idle], "manual"}] do
      job
      |> Job.changeset(%{
        state: "reconciling",
        review_state: review_state,
        reconciling_at: nil,
        absence_observed_at: nil,
        last_error: "Retained-agent recovery was interrupted; work is preserved."
      })
      |> Repo.update!()

      Process.put(:herdr_result, {:ok, observed})
      assert {:ok, %{absent_count: 0}} = Sync.sync(client: FakeClient, session: "held-settle")

      settled = Repo.get!(Job, job.id) |> Repo.preload(:agent_runs)
      assert settled.state == "blocked"
      assert settled.review_state == review_state
      assert settled.last_error =~ "work is preserved"
      assert Operations.review_capacity_released?(settled)
    end

    job
    |> Job.changeset(%{state: "reconciling", review_state: "paused", reconciling_at: now()})
    |> Repo.update!()

    Process.put(
      :herdr_result,
      {:ok, [remote_agent("working") |> Map.put("name", run.agent_name)]}
    )

    assert {:ok, _summary} =
             Sync.sync(client: FakeClient, session: "held-settle", reconcile_after_ms: 0)

    assert Repo.get!(Job, job.id).state == "reconciling"
  end

  test "an active attempt reaches reconciliation without reads under the writer lock" do
    %{job: job, run: run, worker: worker} =
      managed_job_fixture("write-only-terminal", %{agent_name: :deterministic})

    worker
    |> Worker.changeset(%{
      worker_incarnation_id: "terminal-worker",
      herdr_incarnation_id: "terminal-herdr",
      snapshot_sequence: 1,
      healthy_snapshot_count: 2,
      coordinator_incarnation_id: RuntimeIncarnation.current()
    })
    |> Repo.update!()

    remote = remote_agent("done") |> Map.put("name", run.agent_name)
    Process.put(:herdr_result, {:ok, authoritative_snapshot([remote], 2)})

    assert_no_transaction_reads(fn ->
      assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "write-only-terminal")
    end)

    assert Repo.get!(AgentRun, run.id).state == "done"
    assert Repo.get!(Job, job.id).state == "awaiting_reconciliation"
  end

  test "a steady plan cannot overwrite a job changed after projection" do
    %{job: job, run: run, worker: worker} =
      managed_job_fixture("planned-race", %{agent_name: :deterministic})

    worker
    |> Worker.changeset(%{
      worker_incarnation_id: "terminal-worker",
      herdr_incarnation_id: "terminal-herdr",
      snapshot_sequence: 1,
      healthy_snapshot_count: 2,
      coordinator_incarnation_id: RuntimeIncarnation.current()
    })
    |> Repo.update!()

    remote = remote_agent("working") |> Map.put("name", run.agent_name)
    Application.put_env(:ptc_manager, :paused_herdr_test_pid, self())
    on_exit(fn -> Application.delete_env(:ptc_manager, :paused_herdr_test_pid) end)

    handler = "herdr-planned-race-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_manager, :herdr, :snapshot, :planned],
        fn _event, _measurements, _metadata, owner ->
          send(owner, {:snapshot_planned, self()})
          receive do: (:apply_snapshot -> :ok)
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    task = Task.async(fn -> Sync.sync(client: PausedClient, session: "planned-race") end)
    assert_receive {:herdr_snapshot_requested, sync_pid}
    send(sync_pid, {:return_herdr_snapshot, {:ok, authoritative_snapshot([remote], 2)}})
    assert_receive {:snapshot_planned, ^sync_pid}

    job
    |> Job.changeset(%{state: "working", fencing_token: 2, last_error: "newer attempt"})
    |> Repo.update!()

    send(sync_pid, :apply_snapshot)
    assert {:ok, _summary} = Task.await(task)

    unchanged = Repo.get!(Job, job.id)
    assert unchanged.fencing_token == 2
    assert unchanged.last_error == "newer attempt"
  end

  test "an unchanged snapshot refreshes heartbeats without rewriting runs or allocations" do
    %{job: job, run: run, worker: worker} =
      managed_job_fixture("steady", %{agent_name: :deterministic})

    worker =
      worker
      |> Worker.changeset(%{
        worker_incarnation_id: "terminal-worker",
        herdr_incarnation_id: "terminal-herdr",
        snapshot_sequence: 1,
        healthy_snapshot_count: 2,
        coordinator_incarnation_id: RuntimeIncarnation.current()
      })
      |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "active",
        path: "/tmp/steady-worktree",
        herdr_workspace: "steady-workspace",
        last_used_at: now()
      })
      |> Repo.insert!()

    remote =
      remote_agent("working")
      |> Map.put("name", run.agent_name)
      |> Map.put("workspace_id", "steady-workspace")

    Process.put(:herdr_result, {:ok, authoritative_snapshot([remote], 2)})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "steady")

    settled_run = Repo.get!(AgentRun, run.id)
    settled_allocation = Repo.get!(WorktreeAllocation, allocation.id)

    Process.put(:herdr_result, {:ok, authoritative_snapshot([remote], 3)})

    assert_no_transaction_reads(fn ->
      assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "steady")
    end)

    refreshed_run = Repo.get!(AgentRun, run.id)
    assert DateTime.compare(refreshed_run.last_heartbeat_at, settled_run.last_heartbeat_at) == :gt
    assert refreshed_run.updated_at == settled_run.updated_at

    assert Repo.get!(WorktreeAllocation, allocation.id).updated_at ==
             settled_allocation.updated_at
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

  defp managed_job_fixture(session, run_attrs \\ %{}) do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{worker_key: "herdr:#{session}"})
    now = now()

    job =
      job
      |> Job.changeset(%{
        state: "working",
        fencing_token: 1,
        lease_owner: worker.worker_key,
        lease_expires_at: DateTime.add(now, 60, :second),
        branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
      })
      |> Repo.update!()

    run_attrs =
      Map.merge(
        %{
          worker_id: worker.id,
          job_id: job.id,
          role: "implementer",
          state: "working",
          started_at: DateTime.add(now, -60, :second),
          last_heartbeat_at: now,
          external_key: "#{session}:agent-history",
          fencing_token: 1
        },
        run_attrs
      )
      |> Map.update(:agent_name, nil, fn
        :deterministic -> "impl_j#{job.id}_f1"
        name -> name
      end)

    {:ok, run} = Operations.create_agent_run(run_attrs)
    %{issue: issue, job: job, run: run, worker: worker}
  end

  defp assert_no_transaction_reads(operation) do
    handler = "herdr-transaction-reads-#{System.unique_integer([:positive])}"
    owner = self()
    transaction_key = {__MODULE__, handler, :transaction}

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_manager, :repo, :query],
        &track_transaction_reads/4,
        {owner, transaction_key}
      )

    try do
      operation.()
      refute_receive {:transaction_read, _source}
    after
      :telemetry.detach(handler)
    end
  end

  defp track_transaction_reads(_event, _measurements, metadata, {pid, transaction_key}) do
    query = to_string(metadata[:query])

    case String.downcase(query) do
      "begin" ->
        Process.put(transaction_key, true)

      outcome when outcome in ["commit", "rollback"] ->
        Process.delete(transaction_key)

      _query ->
        if Process.get(transaction_key) == true and
             (String.starts_with?(query, "SELECT") or String.starts_with?(query, "PRAGMA")) do
          send(pid, {:transaction_read, metadata[:source]})
        end
    end
  end

  defp authoritative_snapshot(agents, sequence) do
    %{
      "agents" => agents,
      "worker_incarnation_id" => "terminal-worker",
      "herdr_incarnation_id" => "terminal-herdr",
      "snapshot_sequence" => sequence
    }
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
