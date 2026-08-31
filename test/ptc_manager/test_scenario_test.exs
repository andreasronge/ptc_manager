defmodule PtcManager.TestScenarioTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions.ExternalPrRepairAdapter
  alias PtcManager.MaintainerActions
  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AgentRun,
    AuditEvent,
    Issue,
    Job,
    PrPublication,
    Worker,
    WorktreeAllocation
  }

  alias PtcManager.Publications
  alias PtcManager.Repo
  alias PtcManager.TestScenario
  alias PtcManager.Worktrees

  test "advances lease expiry with the scenario clock and no wall-clock sleep" do
    now = ~U[2026-08-31 12:00:00.000000Z]
    scenario = start_supervised!({TestScenario, now: now}) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 100)

    assert {:ok, %{job: working}} =
             TestScenario.advance(scenario, :dispatch, lease_ms: 1_000)

    assert DateTime.compare(working.started_at, now) == :gt
    assert working.lease_expires_at == DateTime.add(now, 1_000, :millisecond)

    assert DateTime.add(now, 1_000, :millisecond) ==
             TestScenario.advance_time(scenario, 1_000, :millisecond)

    assert {:ok, :empty} = TestScenario.advance(scenario, :dispatch)

    expired = Repo.get!(Job, job.id)
    assert expired.state == "reconciling"
    assert expired.reconciling_at == DateTime.add(now, 1_000, :millisecond)
    assert expired.last_error =~ "lease expired"
  end

  test "does not accept a dispatch acknowledgement after its virtual lease expires" do
    now = ~U[2026-08-31 12:00:00.000000Z]
    scenario = start_supervised!({TestScenario, now: now}) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 99)
    :ok = TestScenario.dispatch_outcome(scenario, :pause_after_effect)

    task =
      Task.async(fn -> TestScenario.advance(scenario, :dispatch, lease_ms: 1_000) end)

    assert_receive {:scenario_paused_after_effect, reference, :dispatch, job_id}
    assert job_id == job.id
    assert length(TestScenario.agents(scenario)) == 1

    TestScenario.advance_time(scenario, 1_000, :millisecond)
    :ok = TestScenario.resume(scenario, reference)

    assert {:error, :lease_expired} = Task.await(task)
    assert Repo.get!(Job, job.id).state == "starting"

    assert {:ok, :empty} = TestScenario.advance(scenario, :dispatch)
    assert Repo.get!(Job, job.id).state == "reconciling"
    assert length(TestScenario.agents(scenario)) == 1
  end

  test "Herdr heartbeat refreshes a lease using the same virtual clock" do
    now = ~U[2026-08-31 12:00:00.000000Z]
    scenario = start_supervised!({TestScenario, now: now}) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 98)

    assert {:ok, %{job: _working}} =
             TestScenario.advance(scenario, :dispatch, lease_ms: 1_000)

    heartbeat_at = TestScenario.advance_time(scenario, 500, :millisecond)
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    lease_ms = Application.fetch_env!(:ptc_manager, :dispatch_lease_ms)
    refreshed = Repo.get!(Job, job.id)
    assert refreshed.lease_expires_at == DateTime.add(heartbeat_at, lease_ms, :millisecond)

    TestScenario.advance_time(scenario, lease_ms, :millisecond)
    assert {:ok, :empty} = TestScenario.advance(scenario, :dispatch)
    assert Repo.get!(Job, job.id).state == "reconciling"
  end

  test "a future lease clock does not move managed agent lifecycle timestamps" do
    future = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.truncate(:microsecond)
    scenario = start_supervised!({TestScenario, now: future}) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 97)

    assert {:ok, %{job: _working}} = TestScenario.advance(scenario, :dispatch)

    [agent] = TestScenario.agents(scenario)
    :ok = TestScenario.set_agent_state(scenario, agent["name"], "failed")
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    run = Repo.get_by!(AgentRun, job_id: job.id)
    assert run.state == "failed"
    assert DateTime.compare(run.ended_at, run.started_at) != :lt
    assert DateTime.compare(run.started_at, future) == :lt
  end

  test "absent-agent reconciliation uses virtual deadlines and real lifecycle time" do
    future = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.truncate(:microsecond)
    scenario = start_supervised!({TestScenario, now: future}) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 96)
    :ok = TestScenario.dispatch_outcome(scenario, :effect_then_error)

    assert {:error, :scenario_dispatch_ack_lost} =
             TestScenario.advance(scenario, :dispatch)

    [agent] = TestScenario.agents(scenario)
    :ok = TestScenario.remove_agent(scenario, agent["name"])

    assert {:ok, %{absent_count: 0}} =
             TestScenario.advance(scenario, :herdr_sync, reconcile_after_ms: 1_000)

    refute Repo.get!(Job, job.id).absence_observed_at

    deadline = TestScenario.advance_time(scenario, 1_000, :millisecond)

    assert {:ok, %{absent_count: 0}} =
             TestScenario.advance(scenario, :herdr_sync, reconcile_after_ms: 1_000)

    assert Repo.get!(Job, job.id).absence_observed_at == deadline

    assert {:ok, %{absent_count: 1}} =
             TestScenario.advance(scenario, :herdr_sync, reconcile_after_ms: 1_000)

    failed = Repo.get!(Job, job.id)
    assert failed.state == "failed"
    assert DateTime.compare(failed.ended_at, failed.started_at) != :lt
    assert DateTime.compare(failed.ended_at, future) == :lt
  end

  test "adopts a single Herdr agent after start succeeds but acknowledgement is lost" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario)
    :ok = TestScenario.dispatch_outcome(scenario, :effect_then_error)

    assert {:error, :scenario_dispatch_ack_lost} =
             TestScenario.advance(scenario, :dispatch, lease_ms: 60_000)

    assert Repo.get!(Job, job.id).state == "reconciling"
    assert length(TestScenario.agents(scenario)) == 1
    assert Repo.aggregate(AgentRun, :count) == 0

    assert {:ok, %{agent_count: 1}} =
             TestScenario.advance(scenario, :herdr_sync, reconcile_after_ms: 0)

    assert Repo.get!(Job, job.id).state == "working"
    assert Repo.one!(AgentRun).agent_name == "impl_j#{job.id}_f1"

    assert Enum.map(TestScenario.trace(scenario), &{&1.source, &1.operation}) == [
             {:github, :get_issue},
             {:herdr, :dispatch},
             {:herdr, :list_agents}
           ]
  end

  test "advances transport loss and recovery without wall-clock sleeps" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario)

    assert {:ok, %{job: working}} = TestScenario.advance(scenario, :dispatch)
    assert working.state == "working"

    :ok = TestScenario.herdr_transport(scenario, :offline)

    assert {:error, {:offline, %{uncertain_count: 1}}} =
             TestScenario.advance(scenario, :herdr_sync, stale_after_ms: 0)

    assert Repo.get!(Job, job.id).state == "reconciling"
    assert Repo.one!(AgentRun).state == "unknown"

    :ok = TestScenario.herdr_transport(scenario, :online)
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    assert Repo.one!(AgentRun).state == "working"
    assert Repo.get!(Job, job.id).state == "working"

    operations = Enum.map(TestScenario.trace(scenario), &{&1.source, &1.operation})

    assert operations == [
             {:github, :get_issue},
             {:herdr, :dispatch},
             {:herdr, :list_agents},
             {:herdr, :list_agents}
           ]
  end

  test "a worker restart retains the fenced attempt until two healthy snapshots" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 95)

    assert {:ok, %{job: working}} = TestScenario.advance(scenario, :dispatch)
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    initial_worker = Repo.get_by!(Worker, worker_key: "herdr:scenario")
    initial_run = Repo.get_by!(AgentRun, job_id: job.id)
    initial_allocation = Repo.get_by!(WorktreeAllocation, job_id: job.id)

    :ok = TestScenario.restart_worker(scenario, "simulated host restart")

    assert {:ok, %{recovery_pending: true, uncertain_count: 1}} =
             TestScenario.advance(scenario, :herdr_sync)

    recovering_worker = Repo.get!(Worker, initial_worker.id)
    recovering_job = Repo.get!(Job, job.id)
    recovering_run = Repo.get!(AgentRun, initial_run.id)
    recovering_allocation = Repo.get_by!(WorktreeAllocation, job_id: job.id)

    assert recovering_worker.status == "degraded"
    assert recovering_worker.healthy_snapshot_count == 1
    assert recovering_worker.restart_reason == "simulated host restart"
    assert recovering_worker.worker_incarnation_id != initial_worker.worker_incarnation_id

    assert recovering_worker.previous_worker_incarnation_id ==
             initial_worker.worker_incarnation_id

    assert recovering_job.state == "reconciling"
    assert recovering_job.fencing_token == working.fencing_token
    assert recovering_run.state == "unknown"
    assert recovering_allocation.id == initial_allocation.id
    assert recovering_allocation.state == "attention"
    assert {:error, :worker_unavailable} = Operations.dispatch_capacity("herdr:scenario")
    assert length(TestScenario.agents(scenario)) == 1

    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    recovered_worker = Repo.get!(Worker, initial_worker.id)
    recovered_job = Repo.get!(Job, job.id)
    recovered_run = Repo.get!(AgentRun, initial_run.id)
    recovered_allocation = Repo.get_by!(WorktreeAllocation, job_id: job.id)

    assert recovered_worker.status == "online"
    assert recovered_worker.healthy_snapshot_count == 2
    assert recovered_job.state == "working"
    assert recovered_job.fencing_token == working.fencing_token
    assert recovered_run.state == "working"
    assert recovered_allocation.id == initial_allocation.id
    assert recovered_allocation.state == "active"
    assert Repo.aggregate(AgentRun, :count) == 1

    event = Repo.get_by!(AuditEvent, action: "worker.incarnation_changed")
    assert event.target_id == initial_worker.id
    assert event.details["restart_reason"] == "simulated host restart"
  end

  test "a duplicate authoritative snapshot cannot overwrite newer agent state" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 94)

    assert {:ok, %{job: _working}} = TestScenario.advance(scenario, :dispatch)
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    [agent] = TestScenario.agents(scenario)
    :ok = TestScenario.set_agent_state(scenario, agent["name"], "failed")
    :ok = TestScenario.replay_last_snapshot(scenario)

    assert {:ok, %{snapshot_ignored: :stale_sequence}} =
             TestScenario.advance(scenario, :herdr_sync)

    assert Repo.get_by!(AgentRun, job_id: job.id).state == "working"
    assert Repo.get!(Job, job.id).state == "working"
  end

  test "a replayed snapshot eventually closes admission without wall-clock sleep" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 92)

    assert {:ok, %{job: _working}} = TestScenario.advance(scenario, :dispatch)
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    worker = Repo.get_by!(Worker, worker_key: "herdr:scenario")

    worker
    |> Worker.changeset(%{last_heartbeat_at: DateTime.add(worker.last_heartbeat_at, -2, :second)})
    |> Repo.update!()

    :ok = TestScenario.replay_last_snapshot(scenario)

    assert {:ok, %{recovery_pending: true, uncertain_count: 1}} =
             TestScenario.advance(scenario, :herdr_sync, stale_after_ms: 1_000)

    assert Repo.get!(Worker, worker.id).status == "degraded"
    assert Repo.get!(Job, job.id).state == "reconciling"
    assert {:error, :worker_unavailable} = Operations.dispatch_capacity("herdr:scenario")
  end

  test "an identity-enrolled worker is unavailable until this coordinator observes it" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    worker =
      worker_fixture(%{
        worker_key: "herdr:scenario",
        worker_incarnation_id: "scenario-worker-1",
        herdr_incarnation_id: "scenario-herdr-1",
        snapshot_sequence: 0,
        healthy_snapshot_count: 2,
        coordinator_incarnation_id: "previous-coordinator"
      })

    assert {:error, :worker_unavailable} = Operations.dispatch_capacity(worker.worker_key)
    assert {:ok, %{agent_count: 0}} = TestScenario.advance(scenario, :herdr_sync)
    assert {:ok, 1} = Operations.dispatch_capacity(worker.worker_key)
  end

  test "a restart fences a dispatch that is still waiting for its acknowledgement" do
    scenario =
      start_supervised!({TestScenario, pause_owner: self()})
      |> TestScenario.gateway()

    assert {:ok, %{agent_count: 0}} = TestScenario.advance(scenario, :herdr_sync)
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 91)
    :ok = TestScenario.dispatch_outcome(scenario, :pause_after_effect)

    task = Task.async(fn -> TestScenario.advance(scenario, :dispatch) end)
    assert_receive {:scenario_paused_after_effect, reference, :dispatch, job_id}
    assert job_id == job.id
    assert Repo.get!(Job, job.id).state == "starting"
    assert Repo.aggregate(AgentRun, :count) == 0

    :ok = TestScenario.restart_worker(scenario, "restart during dispatch")

    assert {:ok, %{recovery_pending: true, uncertain_count: 1}} =
             TestScenario.advance(scenario, :herdr_sync)

    assert Repo.get!(Job, job.id).state == "reconciling"
    :ok = TestScenario.resume(scenario, reference)
    assert {:error, :invalid_job_state} = Task.await(task)
    assert Repo.aggregate(AgentRun, :count) == 0

    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)
    assert Repo.get!(Job, job.id).state == "working"
    assert Repo.aggregate(AgentRun, :count) == 1
  end

  test "transport recovery requires consecutive authoritative snapshots once identity is known" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 93)

    assert {:ok, %{job: _working}} = TestScenario.advance(scenario, :dispatch)
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    :ok = TestScenario.herdr_transport(scenario, :offline)

    assert {:error, {:offline, %{uncertain_count: 1}}} =
             TestScenario.advance(scenario, :herdr_sync, stale_after_ms: 0)

    :ok = TestScenario.herdr_transport(scenario, :online)

    assert {:ok, %{recovery_pending: true}} = TestScenario.advance(scenario, :herdr_sync)
    assert Repo.get_by!(Worker, worker_key: "herdr:scenario").status == "degraded"
    assert Repo.get!(Job, job.id).state == "reconciling"

    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)
    assert Repo.get_by!(Worker, worker_key: "herdr:scenario").status == "online"
    assert Repo.get!(Job, job.id).state == "working"
  end

  test "a failure before dispatch has no Herdr side effect" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario)
    :ok = TestScenario.dispatch_outcome(scenario, :fail_before)

    assert {:error, :scenario_dispatch_failed} = TestScenario.advance(scenario, :dispatch)
    assert TestScenario.agents(scenario) == []
    assert Repo.get!(Job, job.id).state == "failed"

    dispatch_event = List.last(TestScenario.trace(scenario))
    assert dispatch_event.operation == :dispatch
    assert dispatch_event.outcome.mode == :fail_before
  end

  test "one scenario can queue multiple implementations while reusing its worker" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    first = TestScenario.approved_implementation!(scenario, number: 101)
    second = TestScenario.approved_implementation!(scenario, number: 102)

    assert first.worker.id == second.worker.id
    assert Repo.aggregate(Job, :count) == 2
    assert Enum.map(Operations.list_queued_jobs(), & &1.issue.number) == [101, 102]
  end

  test "GitHub synchronization uses the same stateful scenario boundary" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    fixture = TestScenario.approved_implementation!(scenario, number: 103)

    updated_remote =
      fixture.remote_issue
      |> Map.put("title", "Updated through deterministic GitHub sync")
      |> Map.put("updated_at", "2026-08-31T10:00:00Z")

    :ok = TestScenario.put_issue(scenario, fixture.repository, updated_remote)

    assert {:ok, %{issue_count: 1, changed_count: 1}} =
             TestScenario.advance(scenario, {:github_sync, fixture.repository})

    assert Repo.get!(Issue, fixture.issue.id).title == "Updated through deterministic GitHub sync"

    assert Enum.any?(TestScenario.trace(scenario), fn event ->
             event.source == :github and event.operation == :list_open_issues
           end)
  end

  test "pause after effect creates an explicit interleaving barrier" do
    scenario = start_supervised!({TestScenario, []}) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 104)
    :ok = TestScenario.dispatch_outcome(scenario, :pause_after_effect)

    task = Task.async(fn -> TestScenario.advance(scenario, :dispatch) end)

    assert_receive {:scenario_paused_after_effect, reference, :dispatch, job_id}
    assert job_id == job.id
    assert Repo.get!(Job, job.id).state == "starting"
    assert length(TestScenario.agents(scenario)) == 1
    assert :ok = TestScenario.set_agent_state(scenario, "impl_j#{job.id}_f1", "blocked")

    :ok = TestScenario.resume(scenario, reference)
    assert {:ok, %{job: working}} = Task.await(task)
    assert working.state == "working"
    assert length(TestScenario.agents(scenario)) == 1
  end

  test "external PR repair and cleanup stay inside the stateful Herdr boundary" do
    scenario =
      start_supervised!({TestScenario, now: ~U[2026-08-31 12:00:00.000000Z]})
      |> TestScenario.gateway()

    repository = repository_fixture(%{local_path: "/tmp/ptc-manager-test-scenario"})
    original_head = String.duplicate("b", 40)
    status = external_pr_status(repository, 105, original_head)

    configure_herdr_actions("scenario")

    assert {:ok, %{agent_count: 0}} = TestScenario.advance(scenario, :herdr_sync)

    assert {:ok, _summary} =
             Publications.sync_external_open_pull_requests(repository, [status])

    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 105)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "scenario-maintainer")

    :ok =
      TestScenario.repair_statuses(
        scenario,
        status,
        %{status | head_sha: String.duplicate("e", 40)}
      )

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: scenario, sync: scenario)

    assert completed.id == action.id
    assert completed.state == "done"

    run = Repo.get_by!(AgentRun, agent_action_id: action.id)
    assert run.herdr_workspace
    assert length(TestScenario.agents(scenario)) == 1

    :ok = TestScenario.set_agent_state(scenario, run.agent_name, "failed")
    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)

    failed_run = Repo.get!(AgentRun, run.id)
    assert failed_run.state == "failed"
    assert DateTime.compare(failed_run.ended_at, failed_run.started_at) != :lt

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    publication
    |> PrPublication.changeset(%{pr_state: "merged", merged_at: now})
    |> Repo.update!()

    :ok = TestScenario.cleanup_outcome(scenario, :fail_before)

    assert {:error, {:external_pr_session_cleanup_failed, :scenario_cleanup_failed}} =
             Worktrees.cleanup_terminal_once(scenario, PtcManager.Repository.GitProbe, scenario)

    assert Repo.get!(AgentRun, run.id).herdr_workspace

    :ok = TestScenario.cleanup_outcome(scenario, :ok)

    assert {:ok, cleaned} =
             Worktrees.cleanup_terminal_once(scenario, PtcManager.Repository.GitProbe, scenario)

    assert cleaned.id == run.id
    assert cleaned.herdr_workspace == nil
    assert TestScenario.agents(scenario) == []

    operations = Enum.map(TestScenario.trace(scenario), & &1.operation)
    assert :start_pull_request_action in operations
    assert :prompt_pull_request_action in operations
    assert :pull_request_action_head in operations
    assert Enum.count(operations, &(&1 == :remove_action_workspace)) == 2
  end

  test "a repair start acknowledgement cannot cross an unobserved worker incarnation" do
    scenario =
      start_supervised!({TestScenario, pause_owner: self()})
      |> TestScenario.gateway()

    configure_herdr_actions("scenario")
    assert {:ok, %{agent_count: 0}} = TestScenario.advance(scenario, :herdr_sync)

    repository = repository_fixture(%{local_path: "/tmp/ptc-manager-test-scenario"})
    head = String.duplicate("b", 40)
    status = external_pr_status(repository, 107, head)
    assert {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])

    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 107)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "scenario-maintainer")

    {:ok, _prepared} =
      Operations.record_agent_action_target_snapshot(action.id, %{"head_sha" => head})

    {:ok, {claimed, _token}} = Operations.claim_agent_action(action.id)

    :ok =
      TestScenario.operation_outcome(scenario, :start_pull_request_action, :pause_after_effect)

    task = Task.async(fn -> ExternalPrRepairAdapter.run(claimed, scenario) end)

    assert_receive {:scenario_paused_after_effect, reference, :start_pull_request_action,
                    action_id}

    assert action_id == action.id
    [started_agent] = TestScenario.agents(scenario)
    :ok = TestScenario.remove_agent(scenario, started_agent["name"])
    :ok = TestScenario.restart_worker(scenario, "restart during repair start")

    assert {:ok, %{recovery_pending: true}} = TestScenario.advance(scenario, :herdr_sync)
    assert {:ok, %{agent_count: 0}} = TestScenario.advance(scenario, :herdr_sync)

    :ok = TestScenario.resume(scenario, reference)
    assert {:error, :stale_worker_incarnation} = Task.await(task)

    run = Repo.get_by!(AgentRun, agent_action_id: action.id)
    assert run.state == "unknown"
    refute Enum.any?(TestScenario.trace(scenario), &(&1.operation == :prompt_pull_request_action))
  end

  test "each external PR command has an independently configurable fault outcome" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    repository = repository_fixture(%{local_path: "/tmp/ptc-manager-test-scenario"})
    status = external_pr_status(repository, 106, String.duplicate("b", 40))
    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])
    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 106)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "scenario-maintainer")

    :ok = TestScenario.operation_outcome(scenario, :start_pull_request_action, :fail_before)

    assert {:error, {:start_pull_request_action, :scenario_failed_before}} =
             TestScenario.start_pull_request_action(scenario, action, publication, repository)

    assert TestScenario.agents(scenario) == []

    :ok = TestScenario.operation_outcome(scenario, :start_pull_request_action, :ok)

    assert {:ok, dispatch} =
             TestScenario.start_pull_request_action(scenario, action, publication, repository)

    :ok =
      TestScenario.operation_outcome(scenario, :prompt_pull_request_action, :effect_then_error)

    assert {:error, {:prompt_pull_request_action, :scenario_ack_lost}} =
             TestScenario.prompt_pull_request_action(scenario, dispatch.agent_name, action.prompt)

    :ok = TestScenario.operation_outcome(scenario, :pull_request_action_head, :fail_before)

    assert {:error, {:pull_request_action_head, :scenario_failed_before}} =
             TestScenario.pull_request_action_head(scenario, dispatch.worktree_path)

    modes =
      TestScenario.trace(scenario)
      |> Enum.filter(&(is_map(&1.outcome) and Map.has_key?(&1.outcome, :mode)))
      |> Map.new(&{&1.operation, &1.outcome.mode})

    assert modes.start_pull_request_action == :ok
    assert modes.prompt_pull_request_action == :effect_then_error
    assert modes.pull_request_action_head == :fail_before
  end

  test "GitHub list failure is visible and a later public sync recovers" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    fixture = TestScenario.approved_implementation!(scenario, number: 108)
    :ok = TestScenario.operation_outcome(scenario, :list_open_issues, :fail_before)

    assert {:error, {:list_open_issues, :scenario_failed_before}} =
             TestScenario.advance(scenario, {:github_sync, fixture.repository})

    assert Repo.reload(fixture.repository).sync_status == "error"

    :ok = TestScenario.operation_outcome(scenario, :list_open_issues, :ok)

    assert {:ok, %{issue_count: 1}} =
             TestScenario.advance(scenario, {:github_sync, fixture.repository})

    assert Repo.reload(fixture.repository).sync_status == "ok"
  end

  test "GitHub issue-read failure leaves dispatch queued and can be retried" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario, number: 109)
    :ok = TestScenario.operation_outcome(scenario, :get_issue, :fail_before)

    assert {:error, {:get_issue, :scenario_failed_before}} =
             TestScenario.advance(scenario, :dispatch)

    assert Repo.get!(Job, job.id).state == "queued"

    :ok = TestScenario.operation_outcome(scenario, :get_issue, :ok)
    assert {:ok, %{job: working}} = TestScenario.advance(scenario, :dispatch)
    assert working.id == job.id
  end

  defp configure_herdr_actions(session) do
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    previous_session = Application.get_env(:ptc_manager, :herdr_session)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :herdr_session, session)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :dispatch_enabled, previous_dispatch)
      Application.put_env(:ptc_manager, :herdr_session, previous_session)
    end)
  end
end
