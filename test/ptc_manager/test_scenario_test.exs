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
  alias PtcManager.PublicationStatusReconciler
  alias PtcManager.Publisher
  alias PtcManager.Repo
  alias PtcManager.ResultReconciler
  alias PtcManager.TestScenario
  alias PtcManager.Worktrees

  defmodule MultiRepositoryProbe do
    @behaviour PtcManager.Repository.ResultProbe

    def verify(_repository, job) do
      {:ok,
       %{
         base_sha: sha(job.id, "a"),
         head_sha: sha(job.id, "b"),
         diff_digest: sha(job.id, "c", 64),
         commit_count: 1
       }}
    end

    defp sha(id, character, length \\ 40) do
      id
      |> Integer.to_string(16)
      |> String.pad_leading(length, character)
      |> String.slice(-length, length)
    end
  end

  defmodule MultiRepositoryContract do
    def for_result(_job, _result),
      do: {:ok, PtcManager.RepositoryContractFixture.contract()}
  end

  defmodule MultiRepositoryGate do
    def verify(publication) do
      {:ok,
       %{
         status: "passed",
         verified_sha: publication.head_sha,
         config_digest: publication.job.pre_publication_config_digest,
         exit_status: 0,
         output: "scenario gate passed",
         output_truncated: false,
         duration_ms: 1
       }}
    end
  end

  defmodule MultiRepositoryBroker do
    @behaviour PtcManager.GitHub.PublishBroker

    def publish(publication) do
      repository = publication.repository || publication.job.repository

      {:ok,
       %{
         pr_number: 73,
         pr_url:
           "https://github.com/#{repository.github_owner}/#{repository.github_name}/pull/73",
         head_sha: publication.head_sha
       }}
    end

    def status(_publication), do: {:error, :not_supported}
    def discover(_publication), do: {:error, :not_supported}
  end

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

    assert_receive {:scenario_paused_after_effect, reference, :dispatch, job_id}, 1_000
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
    assert_receive {:scenario_paused_after_effect, reference, :dispatch, job_id}, 1_000
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

  test "same issue and PR numbers stay isolated across the complete two-repository journey" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    first =
      TestScenario.approved_implementation!(scenario,
        number: 501,
        local_path: "/tmp/ptc-manager-golden-alpha",
        repository_attrs: %{github_owner: "golden", github_name: "alpha"}
      )

    second =
      TestScenario.approved_implementation!(scenario,
        number: 501,
        local_path: "/tmp/ptc-manager-golden-beta",
        repository_attrs: %{github_owner: "golden", github_name: "beta"}
      )

    assert first.repository.id != second.repository.id
    assert first.issue.number == second.issue.number

    first_publication = complete_and_publish!(scenario, first.job)
    second_publication = complete_and_publish!(scenario, second.job)

    assert first_publication.pr_number == second_publication.pr_number
    assert first_publication.repository_id == first.repository.id
    assert second_publication.repository_id == second.repository.id
    assert first_publication.head_repository == "golden/alpha"
    assert second_publication.head_repository == "golden/beta"
    assert first_publication.pr_url == "https://github.com/golden/alpha/pull/73"
    assert second_publication.pr_url == "https://github.com/golden/beta/pull/73"

    first_job = Repo.get!(Job, first.job.id)
    second_job = Repo.get!(Job, second.job.id)
    refute first_job.branch_name == second_job.branch_name

    first_allocation = Repo.get_by!(WorktreeAllocation, job_id: first_job.id)
    second_allocation = Repo.get_by!(WorktreeAllocation, job_id: second_job.id)
    worktree_root = Application.fetch_env!(:ptc_manager, :worktree_root) |> Path.expand()

    assert first_allocation.path ==
             Path.join(
               worktree_root,
               "golden-alpha-job-#{first_job.id}-f#{first_job.fencing_token}"
             )

    assert second_allocation.path ==
             Path.join(
               worktree_root,
               "golden-beta-job-#{second_job.id}-f#{second_job.fencing_token}"
             )

    put_merged_status!(scenario, first_publication, first.repository)
    put_merged_status!(scenario, second_publication, second.repository)

    assert {:ok, %{id: first_publication_id, pr_state: "merged"}} =
             PublicationStatusReconciler.run_once(client: scenario, external: false)

    assert first_publication_id == first_publication.id

    assert {:ok, %{id: second_publication_id, pr_state: "merged"}} =
             PublicationStatusReconciler.run_once(client: scenario, external: false)

    assert second_publication_id == second_publication.id

    status_targets =
      scenario
      |> TestScenario.trace()
      |> Enum.filter(&(&1.operation == :pull_request_status))
      |> Enum.map(& &1.target)

    assert status_targets == [
             {first.repository.id, first_publication.pr_number},
             {second.repository.id, second_publication.pr_number}
           ]

    assert :ok = Worktrees.cleanup_terminal_once(scenario, MultiRepositoryProbe, scenario)
    assert :ok = Worktrees.cleanup_terminal_once(scenario, MultiRepositoryProbe, scenario)

    assert Repo.get!(WorktreeAllocation, first_allocation.id).state == "removed"
    assert Repo.get!(WorktreeAllocation, second_allocation.id).state == "removed"
    assert Repo.get!(Job, first_job.id).state == "done"
    assert Repo.get!(Job, second_job.id).state == "done"

    assert Repo.get_by!(Issue, repository_id: first.repository.id, number: 501).id ==
             first.issue.id

    assert Repo.get_by!(Issue, repository_id: second.repository.id, number: 501).id ==
             second.issue.id

    cleanup_targets =
      scenario
      |> TestScenario.trace()
      |> Enum.filter(&(&1.operation == :remove_worktree))
      |> Enum.map(& &1.target)

    assert cleanup_targets == [
             %{
               allocation_id: first_allocation.id,
               workspace: first_allocation.herdr_workspace,
               path: first_allocation.path
             },
             %{
               allocation_id: second_allocation.id,
               workspace: second_allocation.herdr_workspace,
               path: second_allocation.path
             }
           ]

    assert TestScenario.agents(scenario) == []
  end

  test "scenario cleanup rejects a workspace that Herdr never created" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    assert {:error, :scenario_workspace_not_found} =
             TestScenario.remove_worktree(scenario, %{
               id: -1,
               herdr_workspace: "scenario-never-created",
               path: "/tmp/scenario-never-created"
             })

    assert TestScenario.agents(scenario) == []
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

    assert_receive {:scenario_paused_after_effect, reference, :dispatch, job_id}, 1_000
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
                    action_id},
                   1_000

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

  defp complete_and_publish!(scenario, job) do
    assert {:ok, %{job: working}} = TestScenario.advance(scenario, :dispatch)
    assert working.id == job.id

    agent_name = "impl_j#{job.id}_f#{working.fencing_token}"
    :ok = TestScenario.set_agent_state(scenario, agent_name, "done")
    assert {:ok, %{agent_count: agent_count}} = TestScenario.advance(scenario, :herdr_sync)
    assert agent_count >= 1
    assert Repo.get!(Job, job.id).state == "awaiting_reconciliation"

    assert {:ok, %{state: "ready_for_pr"}} =
             ResultReconciler.run_job(job.id,
               probe: MultiRepositoryProbe,
               contract_provider: MultiRepositoryContract
             )

    publication = Repo.get_by!(PrPublication, job_id: job.id)

    assert {:ok, published} =
             Publisher.run_publication(publication.id,
               probe: MultiRepositoryProbe,
               broker: MultiRepositoryBroker,
               gate: MultiRepositoryGate
             )

    assert published.state == "published"
    published
  end

  defp put_merged_status!(scenario, publication, repository) do
    status = %{
      state: "merged",
      pr_url: publication.pr_url,
      draft: false,
      body: "Closes ##{publication.job.issue.number}",
      head_sha: publication.remote_head_sha,
      head_ref: publication.branch_name,
      head_repository: "#{repository.github_owner}/#{repository.github_name}",
      base_sha: publication.base_sha,
      base_ref: repository.default_branch,
      base_repository: "#{repository.github_owner}/#{repository.github_name}"
    }

    :ok =
      TestScenario.put_pull_request_status(
        scenario,
        repository,
        publication.pr_number,
        status
      )
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
