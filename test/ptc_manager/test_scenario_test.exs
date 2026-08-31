defmodule PtcManager.TestScenarioTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentRun, Issue, Job, PrPublication}
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
end
