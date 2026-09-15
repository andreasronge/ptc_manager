defmodule PtcManager.ResourceOperationBrokerTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.ManagedOperationContext
  alias PtcManager.Operations
  alias PtcManager.Operations.ResourceOperation
  alias PtcManager.Operations.Job
  alias PtcManager.Repo
  alias PtcManager.ResourceOperationBroker

  defmodule Recovery do
    def recover(operation) do
      send(
        Application.fetch_env!(:ptc_manager, :operation_recovery_test_pid),
        {:recover, operation}
      )

      Application.get_env(:ptc_manager, :operation_recovery_test_result, :recovered)
    end
  end

  test "a review request from an old pane cannot recreate its agent run" do
    context = managed_run_fixture()

    directory =
      Path.join(System.tmp_dir!(), "ptc-review-context-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, issued} =
      ManagedOperationContext.issue(
        %{
          owner_type: "job",
          owner_id: context.job.id,
          repository_id: context.repository.id,
          worker_id: context.worker.id,
          pane_id: "old-review-pane",
          fencing_token: 4
        },
        directory: directory
      )

    before = Repo.aggregate(PtcManager.Operations.AgentRun, :count)

    response =
      ResourceOperationBroker.dispatch(%{
        "token" => issued.token,
        "context_id" => issued.payload["context_id"],
        "operation" => "review",
        "request_id" => "stale-pane"
      })

    assert response["status"] == "error"
    assert Repo.aggregate(PtcManager.Operations.AgentRun, :count) == before
  end

  test "signed context drives the generic broker protocol without parsing agent output" do
    context = managed_run_fixture()

    directory =
      Path.join(System.tmp_dir!(), "ptc-operation-context-#{System.unique_integer([:positive])}")

    assert {:ok, issued} =
             ManagedOperationContext.issue(
               %{
                 owner_type: "job",
                 owner_id: context.job.id,
                 repository_id: context.repository.id,
                 worker_id: context.worker.id,
                 pane_id: "pane-operation-test",
                 fencing_token: 4
               },
               directory: directory
             )

    assert {:ok, payload} = ManagedOperationContext.verify(issued.token)
    assert payload["owner_id"] == context.job.id
    assert {:ok, %{mode: mode}} = File.stat(issued.path)
    assert Bitwise.band(mode, 0o777) == 0o440

    assert ManagedOperationContext.shell_command(issued.path, payload) =~
             "export PTC_MANAGED_OPERATION_CONTEXT="

    assert {:error, :invalid_managed_operation_context} =
             ManagedOperationContext.verify(issued.token <> "x")

    common = %{
      "token" => issued.token,
      "context_id" => issued.payload["context_id"]
    }

    requested =
      ResourceOperationBroker.dispatch(
        Map.merge(common, %{
          "operation" => "request",
          "invocation_id" => "broker-invocation",
          "label" => "test",
          "priority" => 25
        })
      )

    assert requested["status"] == "queued"

    acquired =
      ResourceOperationBroker.dispatch(
        Map.merge(common, %{
          "operation" => "acquire",
          "operation_id" => requested["operation_id"]
        })
      )

    assert acquired["status"] == "starting"
    assert acquired["slot_number"] == 1

    running =
      ResourceOperationBroker.dispatch(
        Map.merge(common, %{
          "operation" => "running",
          "operation_id" => requested["operation_id"],
          "attempt_token" => acquired["attempt_token"],
          "wrapper_pid" => 4321
        })
      )

    assert running["status"] == "running"

    completed =
      ResourceOperationBroker.dispatch(
        Map.merge(common, %{
          "operation" => "finish",
          "operation_id" => requested["operation_id"],
          "attempt_token" => acquired["attempt_token"],
          "exit_status" => 0,
          "peak_memory_bytes" => 98_765
        })
      )

    assert completed["status"] == "completed"
    operation = Repo.get!(ResourceOperation, requested["operation_id"])
    assert operation.peak_memory_bytes == 98_765
    assert operation.priority == 300
    assert context.run.id == operation.agent_run_id

    File.rm_rf!(directory)
  end

  test "Linux containment is explicit in the pane command only when enabled" do
    previous = Application.get_env(:ptc_manager, :resource_operation_cgroups)
    Application.put_env(:ptc_manager, :resource_operation_cgroups, true)
    on_exit(fn -> Application.put_env(:ptc_manager, :resource_operation_cgroups, previous) end)

    directory =
      Path.join(System.tmp_dir!(), "ptc-cgroup-context-#{System.unique_integer([:positive])}")

    assert {:ok, issued} =
             ManagedOperationContext.issue(
               %{
                 owner_type: "job",
                 owner_id: 1,
                 repository_id: 1,
                 worker_id: 1,
                 pane_id: "pane",
                 fencing_token: 1
               },
               directory: directory
             )

    command = ManagedOperationContext.shell_command(issued.path, issued.payload)
    assert command =~ ". '/usr/local/libexec/ptc-manager-agent-context'"
    assert command =~ "'PTC_OPERATION_CONTEXT_READY'"
    assert command =~ issued.payload["context_id"]
    refute command =~ "PTC_OPERATION_CONTEXT_READY:#{issued.payload["context_id"]}"
    File.rm_rf!(directory)
  end

  test "terminal owner contexts are removed without touching active contexts" do
    directory =
      Path.join(System.tmp_dir!(), "ptc-context-cleanup-#{System.unique_integer([:positive])}")

    {:ok, active} =
      ManagedOperationContext.issue(%{owner_type: "job", owner_id: 10}, directory: directory)

    {:ok, terminal} =
      ManagedOperationContext.issue(%{owner_type: "job", owner_id: 20}, directory: directory)

    terminal_environment = Path.rootname(terminal.path, ".json") <> ".env"
    File.write!(terminal_environment, "TOKEN='secret'\n")

    assert :ok =
             ManagedOperationContext.cleanup_inactive(
               &(&1["owner_id"] == 10),
               directory
             )

    assert File.exists?(active.path)
    refute File.exists?(terminal.path)
    refute File.exists?(terminal_environment)
    File.rm_rf!(directory)
  end

  test "a pane context is atomically rebound from a job to a later repair action" do
    previous_socket = Application.get_env(:ptc_manager, :resource_operation_socket_path)
    previous_directory = Application.get_env(:ptc_manager, :resource_operation_context_dir)

    directory =
      Path.join(System.tmp_dir!(), "ptc-pane-rebind-#{System.unique_integer([:positive])}")

    Application.put_env(:ptc_manager, :resource_operation_socket_path, "/tmp/test.sock")
    Application.put_env(:ptc_manager, :resource_operation_context_dir, directory)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :resource_operation_socket_path, previous_socket)
      Application.put_env(:ptc_manager, :resource_operation_context_dir, previous_directory)
      File.rm_rf!(directory)
    end)

    context = managed_run_fixture()

    {:ok, queued} =
      PtcManager.MaintainerActions.enqueue("prepare_issue", context.issue.id, "maintainer")

    {:ok, {action, _token}} = Operations.claim_agent_action(queued.id)

    assert {:ok, rebound} = ManagedOperationContext.rebind_action("pane-operation-test", action)
    environment_path = Path.rootname(rebound.path, ".json") <> ".env"
    File.write!(environment_path, "SHOULD_NOT_REACH_ACTIONS='secret'\n")
    assert {:ok, repeated} = ManagedOperationContext.rebind_action("pane-operation-test", action)
    assert repeated.path == rebound.path
    refute File.exists?(environment_path)
    assert {:ok, payload} = ManagedOperationContext.verify(rebound.token)
    assert payload["owner_type"] == "agent_action"
    assert payload["owner_id"] == action.id
  end

  test "the broker sweep terminates and releases stale leased operations" do
    previous = Application.get_env(:ptc_manager, :resource_operation_recovery)
    Application.put_env(:ptc_manager, :resource_operation_recovery, Recovery)
    Application.put_env(:ptc_manager, :operation_recovery_test_pid, self())

    on_exit(fn ->
      Application.put_env(:ptc_manager, :resource_operation_recovery, previous)
      Application.delete_env(:ptc_manager, :operation_recovery_test_pid)
    end)

    context = managed_run_fixture()
    stale = DateTime.add(DateTime.utc_now(), -60, :second)

    {:ok, _operation} =
      PtcManager.ResourceOperations.request(
        %{
          worker_id: context.worker.id,
          repository_id: context.repository.id,
          job_id: context.job.id,
          agent_run_id: context.run.id,
          invocation_id: "broker-stale-recovery",
          label: "test",
          priority: 300,
          state: "queued"
        },
        stale
      )

    {:ok, operation} = PtcManager.ResourceOperations.claim_next(context.worker.id, stale)

    {:ok, operation} =
      PtcManager.ResourceOperations.mark_running(
        operation.id,
        operation.attempt_token,
        %{},
        stale
      )

    ResourceOperationBroker.sweep()

    assert_receive {:recover, %{id: id}}
    assert id == operation.id
    assert Repo.get!(ResourceOperation, id).state == "lost"
  end

  test "repeated recovery contention enters maintenance after the retry bound" do
    configure_recovery({:retry, "operation slot lock is still occupied"})
    previous_mode = Application.get_env(:ptc_manager, :operational_mode)
    previous_timeout = Application.get_env(:ptc_manager, :resource_operation_recovery_retry_ms)
    Application.put_env(:ptc_manager, :operational_mode, :active)
    Application.put_env(:ptc_manager, :resource_operation_recovery_retry_ms, 30_000)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :operational_mode, previous_mode)
      Application.put_env(:ptc_manager, :resource_operation_recovery_retry_ms, previous_timeout)
    end)

    operation = stale_running_operation("broker-recovery-retry")
    ResourceOperationBroker.sweep()

    first_retry = Repo.get!(ResourceOperation, operation.id)
    assert first_retry.state == "recovery_pending"
    assert first_retry.last_error =~ "Recovery is waiting"
    assert PtcManager.OperationalMode.mode() == :active

    ResourceOperationBroker.sweep()

    escalated = Repo.get!(ResourceOperation, operation.id)
    assert escalated.state == "recovery_pending"
    assert escalated.last_error =~ "exceeded its retry bound"
    assert PtcManager.OperationalMode.mode() == :maintenance

    assert %{actor: "broker_recovery", details: %{"next" => "maintenance"}} =
             PtcManager.OperationalMode.Audit.last_transition()
  end

  test "a recovery evaluation error is surfaced immediately" do
    configure_recovery({:error, {:operation_recovery_failed, 74, "cannot open lock"}})
    previous_mode = Application.get_env(:ptc_manager, :operational_mode)
    Application.put_env(:ptc_manager, :operational_mode, :active)
    on_exit(fn -> Application.put_env(:ptc_manager, :operational_mode, previous_mode) end)

    operation = stale_running_operation("broker-recovery-error")
    ResourceOperationBroker.sweep()

    failed = Repo.get!(ResourceOperation, operation.id)
    assert failed.state == "recovery_pending"
    assert failed.last_error =~ "could not evaluate"
    assert PtcManager.OperationalMode.mode() == :maintenance
  end

  defp configure_recovery(result) do
    previous = Application.get_env(:ptc_manager, :resource_operation_recovery)
    Application.put_env(:ptc_manager, :resource_operation_recovery, Recovery)
    Application.put_env(:ptc_manager, :operation_recovery_test_pid, self())
    Application.put_env(:ptc_manager, :operation_recovery_test_result, result)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :resource_operation_recovery, previous)
      Application.delete_env(:ptc_manager, :operation_recovery_test_pid)
      Application.delete_env(:ptc_manager, :operation_recovery_test_result)
    end)
  end

  defp stale_running_operation(invocation_id) do
    context = managed_run_fixture()
    stale = DateTime.add(DateTime.utc_now(), -60, :second)

    {:ok, _operation} =
      PtcManager.ResourceOperations.request(
        %{
          worker_id: context.worker.id,
          repository_id: context.repository.id,
          job_id: context.job.id,
          agent_run_id: context.run.id,
          invocation_id: invocation_id,
          label: "test",
          priority: 300,
          state: "queued"
        },
        stale
      )

    {:ok, operation} = PtcManager.ResourceOperations.claim_next(context.worker.id, stale)

    {:ok, operation} =
      PtcManager.ResourceOperations.mark_running(
        operation.id,
        operation.attempt_token,
        %{},
        stale
      )

    operation
  end

  defp managed_run_fixture do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
    job = job |> Job.changeset(%{state: "working"}) |> Repo.update!()
    worker = worker_fixture(%{worker_incarnation_id: "worker-incarnation"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now,
        herdr_pane: "pane-operation-test",
        fencing_token: 4
      })

    %{repository: repository, issue: issue, job: job, worker: worker, run: run}
  end
end
