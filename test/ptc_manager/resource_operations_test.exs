defmodule PtcManager.ResourceOperationsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.ResourceOperation
  alias PtcManager.Repo
  alias PtcManager.ResourceOperations
  alias PtcManager.ResourceOperationRecovery

  setup do
    setting = PtcManager.CapacitySettings.current()

    on_exit(fn ->
      PtcManager.CapacitySettings.update(%{
        light_agent_capacity: setting.light_agent_capacity,
        heavy_agent_capacity: setting.heavy_agent_capacity,
        operation_capacity: setting.operation_capacity
      })
    end)

    :ok
  end

  test "one logical invocation is idempotent but later commands with the same label are distinct" do
    context = managed_run_fixture()
    attrs = operation_attrs(context, "invocation-one")

    assert {:ok, first} = ResourceOperations.request(attrs)
    assert {:ok, duplicate} = ResourceOperations.request(attrs)
    assert duplicate.id == first.id

    assert {:ok, second} =
             ResourceOperations.request(operation_attrs(context, "invocation-two"))

    assert second.id != first.id
    assert Repo.aggregate(ResourceOperation, :count) == 2
  end

  test "priority ordering and operation capacity serialize expensive work" do
    set_operation_capacity(1)
    context = managed_run_fixture()

    assert {:ok, low} =
             ResourceOperations.request(operation_attrs(context, "low", %{priority: 10}))

    assert {:ok, high} =
             ResourceOperations.request(operation_attrs(context, "high", %{priority: 100}))

    assert {:ok, claimed_high} = ResourceOperations.claim_next(context.worker.id)
    assert claimed_high.id == high.id
    assert claimed_high.slot_number == 1
    assert claimed_high.fencing_token == 1
    assert {:ok, :empty} = ResourceOperations.claim_next(context.worker.id)

    assert {:ok, running} =
             ResourceOperations.mark_running(claimed_high.id, claimed_high.attempt_token, %{
               wrapper_pid: 123,
               cgroup_path: "/ptc/operation/high"
             })

    assert running.state == "running"
    assert context.run.id == running.agent_run_id
    assert Repo.get!(PtcManager.Operations.AgentRun, context.run.id).state == "working"

    assert {:ok, completed} =
             ResourceOperations.finish(running.id, running.attempt_token, %{
               exit_status: 0,
               peak_memory_bytes: 42_000
             })

    assert completed.state == "completed"
    assert completed.peak_memory_bytes == 42_000

    assert {:ok, claimed_low} = ResourceOperations.claim_next(context.worker.id)
    assert claimed_low.id == low.id
    assert claimed_low.slot_number == 1
  end

  test "cancellation does not release a running slot until the process reports terminal" do
    set_operation_capacity(1)
    context = managed_run_fixture()

    {:ok, _first} = ResourceOperations.request(operation_attrs(context, "first"))
    {:ok, _second} = ResourceOperations.request(operation_attrs(context, "second"))
    {:ok, first} = ResourceOperations.claim_next(context.worker.id)
    {:ok, first} = ResourceOperations.mark_running(first.id, first.attempt_token)

    assert {:ok, cancelling} = ResourceOperations.cancel(first.id, "job cancelled")
    assert cancelling.state == "cancelling"
    assert {:ok, :empty} = ResourceOperations.claim_next(context.worker.id)
    assert {:error, :stale_operation_lease} = ResourceOperations.finish(first.id, "wrong-token")

    assert {:ok, cancelled} =
             ResourceOperations.finish(first.id, first.attempt_token, %{exit_status: 143})

    assert cancelled.state == "cancelled"
    assert {:ok, replacement} = ResourceOperations.claim_next(context.worker.id)
    assert replacement.label == "test"
  end

  test "a stale operation keeps its fenced slot and is adopted by the same wrapper token" do
    set_operation_capacity(1)
    context = managed_run_fixture()
    base = ~U[2026-09-01 12:00:00.000000Z]

    {:ok, _first} = ResourceOperations.request(operation_attrs(context, "recover-first"), base)
    {:ok, _second} = ResourceOperations.request(operation_attrs(context, "recover-second"), base)
    {:ok, first} = ResourceOperations.claim_next(context.worker.id, base)
    {:ok, first} = ResourceOperations.mark_running(first.id, first.attempt_token, %{}, base)

    assert ResourceOperations.mark_stale_recovery_pending(
             DateTime.add(base, 20, :second),
             15_000
           ) == 1

    recovering = Repo.get!(ResourceOperation, first.id)
    assert recovering.state == "recovery_pending"
    assert recovering.slot_number == 1
    assert {:ok, :empty} = ResourceOperations.claim_next(context.worker.id)

    assert {:ok, adopted} =
             ResourceOperations.heartbeat(
               first.id,
               first.attempt_token,
               DateTime.add(base, 21, :second)
             )

    assert adopted.state == "running"
    assert adopted.slot_number == 1
    assert adopted.last_error == nil
  end

  test "a queued wrapper heartbeat prevents expiry and an abandoned wrapper is cancelled" do
    context = managed_run_fixture()
    base = ~U[2026-09-01 12:00:00.000000Z]

    {:ok, operation} = ResourceOperations.request(operation_attrs(context, "queued-live"), base)

    assert :ok =
             ResourceOperations.heartbeat_queued(operation.id, DateTime.add(base, 10, :second))

    assert ResourceOperations.expire_stale_queued(DateTime.add(base, 20, :second), 15_000) == 0
    assert ResourceOperations.expire_stale_queued(DateTime.add(base, 30, :second), 15_000) == 1
    assert Repo.get!(ResourceOperation, operation.id).state == "cancelled"
  end

  test "a recovered process tree releases its fenced slot without accepting its old token again" do
    set_operation_capacity(1)
    context = managed_run_fixture()
    base = ~U[2026-09-01 12:00:00.000000Z]

    {:ok, _first} = ResourceOperations.request(operation_attrs(context, "abandoned"), base)
    {:ok, second} = ResourceOperations.request(operation_attrs(context, "replacement"), base)
    {:ok, first} = ResourceOperations.claim_next(context.worker.id, base)
    {:ok, first} = ResourceOperations.mark_running(first.id, first.attempt_token, %{}, base)
    assert ResourceOperations.mark_stale_recovery_pending(DateTime.add(base, 20, :second)) == 1

    assert {:ok, released} =
             ResourceOperations.release_recovered(
               first.id,
               first.attempt_token,
               "recovered",
               DateTime.add(base, 21, :second)
             )

    assert released.state == "lost"
    assert is_nil(released.slot_number)
    assert {:ok, replacement} = ResourceOperations.claim_next(context.worker.id)
    assert replacement.id == second.id
    assert {:ok, ^released} = ResourceOperations.finish(first.id, first.attempt_token)
  end

  test "a wrapper that finishes during recovery keeps the stalled heartbeat as the reason" do
    context = managed_run_fixture()
    base = ~U[2026-09-01 12:00:00.000000Z]

    {:ok, _operation} = ResourceOperations.request(operation_attrs(context, "killed"), base)
    {:ok, operation} = ResourceOperations.claim_next(context.worker.id, base)

    {:ok, operation} =
      ResourceOperations.mark_running(operation.id, operation.attempt_token, %{}, base)

    assert ResourceOperations.mark_stale_recovery_pending(DateTime.add(base, 20, :second)) == 1

    # Recovery writes cgroup.kill, so the wrapper sees SIGKILL and reports
    # 137 before the sweep can release the row as lost.
    assert {:ok, finished} =
             ResourceOperations.finish(
               operation.id,
               operation.attempt_token,
               %{exit_status: 137, last_error: nil},
               DateTime.add(base, 21, :second)
             )

    assert finished.state == "failed"
    assert finished.exit_status == 137
    assert finished.last_error =~ "heartbeat stopped"
    assert finished.last_error =~ "recovery"
  end

  test "a finish with processes remaining keeps the slot fenced" do
    set_operation_capacity(1)
    context = managed_run_fixture()
    base = ~U[2026-09-01 12:00:00.000000Z]

    {:ok, _first} = ResourceOperations.request(operation_attrs(context, "survivor"), base)
    {:ok, _second} = ResourceOperations.request(operation_attrs(context, "waiting"), base)
    {:ok, first} = ResourceOperations.claim_next(context.worker.id, base)
    {:ok, first} = ResourceOperations.mark_running(first.id, first.attempt_token, %{}, base)

    assert {:ok, fenced} =
             ResourceOperations.finish(
               first.id,
               first.attempt_token,
               %{
                 exit_status: 0,
                 processes_remaining: true,
                 remaining_processes: [
                   %{"pid" => 4321, "stat" => "S", "command" => "mix phx.server"}
                 ],
                 remaining_detail: nil
               },
               DateTime.add(base, 5, :second)
             )

    assert fenced.state == "recovery_pending"
    assert fenced.slot_number == 1
    assert fenced.exit_status == 0
    assert is_nil(fenced.finished_at)
    assert fenced.last_error =~ "still running"
    assert fenced.last_error =~ "pid 4321 (S) mix phx.server"

    assert %{"processes" => [%{"pid" => 4321, "command" => "mix phx.server"}]} =
             fenced.remaining_processes

    assert {:ok, :empty} = ResourceOperations.claim_next(context.worker.id)

    # A heartbeat the wrapper sent before finishing must not lift the fence.
    assert {:ok, still_fenced} =
             ResourceOperations.heartbeat(
               first.id,
               first.attempt_token,
               DateTime.add(base, 6, :second)
             )

    assert still_fenced.state == "recovery_pending"
    assert {:ok, :empty} = ResourceOperations.claim_next(context.worker.id)
  end

  test "recovery without cgroup containment keeps the slot fenced for a retry" do
    with_env(host_profile: :linux)

    assert {:retry, :operation_recovery_requires_cgroup_containment} =
             ResourceOperationRecovery.recover(%ResourceOperation{wrapper_pid: 999_999})
  end

  test "a host without containment fences the operation with fresh evidence" do
    lock_directory = temporary_lock_directory()
    File.write!(Path.join(lock_directory, "operation-slot-1.lock"), "")

    operation = %ResourceOperation{
      id: 4_242,
      attempt_token: "fence-test-token-0123",
      wrapper_pid: 999_999,
      slot_number: 1
    }

    assert {:fenced, evidence} = ResourceOperationRecovery.recover(operation)
    assert evidence["processes"] == []
    assert evidence["listing_error"] == nil
    assert evidence["lock"] == "free"
    assert evidence["wrapper_pid"] == 999_999
    assert evidence["slot_number"] == 1
    assert evidence["wrapper_alive"] == false

    # A wrapper that vanished before creating its slot lock leaves no lock.
    File.rm!(Path.join(lock_directory, "operation-slot-1.lock"))
    assert {:fenced, %{"lock" => "free"}} = ResourceOperationRecovery.recover(operation)
    assert {:ok, %{mode: mode}} = File.stat(Path.join(lock_directory, "operation-slot-1.lock"))
    assert Bitwise.band(mode, 0o777) == 0o660

    with_env(herdr_run_as_user: "ptc-worker")
    assert {:fenced, %{"listing_error" => unseen}} = ResourceOperationRecovery.recover(operation)
    assert unseen =~ "agent account ptc-worker cannot be listed"
    Application.put_env(:ptc_manager, :herdr_run_as_user, nil)

    Application.put_env(:ptc_manager, :resource_operation_wrapper, "/nonexistent/ptc-operation")

    assert {:fenced, %{"inspection_error" => "the wrapper could not run" <> _}} =
             ResourceOperationRecovery.recover(operation)
  end

  test "a maintainer release needs a free slot lock and accepted processes" do
    set_operation_capacity(1)
    lock_directory = temporary_lock_directory()
    lock = Path.join(lock_directory, "operation-slot-1.lock")
    File.write!(lock, "")
    operation = fenced_operation("release-guarded")

    holder = hold_lock(lock)

    assert {:error, {:slot_lock_held, 999_999}} =
             ResourceOperationRecovery.release(operation, "maintainer", true)

    Port.close(holder)
    wait_until_free(lock)

    marker = "#{operation.id}-#{String.slice(operation.attempt_token, 0, 12)}"
    survivor = spawn_marked(marker)

    assert {:error, :processes_listed} =
             ResourceOperationRecovery.release(operation, "maintainer", false)

    refute ResourceOperationRecovery.processes_may_remain?(%{"processes" => []})

    assert ResourceOperationRecovery.processes_may_remain?(%{
             "processes" => [],
             "listing_error" => "process listing failed: ps"
           })

    assert {:ok, released} = ResourceOperationRecovery.release(operation, "maintainer", true)
    System.cmd("kill", ["-KILL", survivor], stderr_to_stdout: true)
    assert released.state == "lost"
    assert is_nil(released.slot_number)

    assert %{actor: "maintainer", details: details} =
             Repo.get_by!(PtcManager.Operations.AuditEvent,
               action: "resource_operation.released",
               target_id: operation.id
             )

    assert details["processes_listed"] == true
    assert [%{"pid" => pid}] = details["evidence"]["processes"]
    assert Integer.to_string(pid) == survivor
  end

  test "a release loses cleanly to a heartbeat, a late finish or a cancel" do
    lock_directory = temporary_lock_directory()
    File.write!(Path.join(lock_directory, "operation-slot-1.lock"), "")

    for {invocation, change} <- [
          {"race-heartbeat",
           fn operation -> ResourceOperations.heartbeat(operation.id, operation.attempt_token) end},
          {"race-finish",
           fn operation ->
             ResourceOperations.finish(operation.id, operation.attempt_token, %{exit_status: 0})
           end},
          {"race-cancel", fn operation -> ResourceOperations.cancel(operation.id, "stop") end},
          {"race-remaining",
           fn operation ->
             ResourceOperations.finish(operation.id, operation.attempt_token, %{
               exit_status: 0,
               processes_remaining: true,
               remaining_processes: [],
               remaining_detail: "late"
             })
           end}
        ] do
      set_operation_capacity(1)
      operation = fenced_operation(invocation, false)
      {:ok, _changed} = change.(operation)

      assert {:error, :operation_changed} =
               ResourceOperations.release_fenced(operation, "maintainer", %{"processes" => []})

      refute Repo.get_by(PtcManager.Operations.AuditEvent,
               action: "resource_operation.released",
               target_id: operation.id
             )

      Repo.delete_all(ResourceOperation)
    end
  end

  test "statistics use deterministic nearest-rank percentiles" do
    set_operation_capacity(1)
    context = managed_run_fixture()
    base = ~U[2026-09-01 10:00:00.000000Z]

    Enum.each([100, 200, 300, 400, 500], fn duration ->
      invocation = "stats-#{duration}"
      queued_at = DateTime.add(base, duration, :second)
      started_at = DateTime.add(queued_at, 20, :millisecond)
      finished_at = DateTime.add(started_at, duration, :millisecond)

      {:ok, _operation} =
        ResourceOperations.request(operation_attrs(context, invocation), queued_at)

      {:ok, operation} = ResourceOperations.claim_next(context.worker.id, started_at)

      {:ok, operation} =
        ResourceOperations.mark_running(operation.id, operation.attempt_token, %{}, started_at)

      assert {:ok, _operation} =
               ResourceOperations.finish(
                 operation.id,
                 operation.attempt_token,
                 %{exit_status: 0, peak_memory_bytes: duration * 1_000},
                 finished_at
               )
    end)

    stats =
      ResourceOperations.statistics(
        worker_id: context.worker.id,
        from: DateTime.add(base, -1, :second),
        to: DateTime.add(base, 10, :minute)
      )

    assert stats.count == 5
    assert stats.success_rate == 1.0
    assert stats.total_duration_ms == 1_500
    assert stats.average_duration_ms == 300
    assert stats.p20_duration_ms == 100
    assert stats.p50_duration_ms == 300
    assert stats.p80_duration_ms == 400
    assert stats.max_duration_ms == 500
    assert stats.average_wait_ms == 20
    assert stats.p80_peak_memory_bytes == 400_000
    assert stats.max_peak_memory_bytes == 500_000
  end

  test "lost recovered operations remain visible in statistics" do
    set_operation_capacity(1)
    context = managed_run_fixture()
    base = ~U[2026-09-01 10:00:00.000000Z]

    {:ok, _operation} = ResourceOperations.request(operation_attrs(context, "lost-stat"), base)
    {:ok, operation} = ResourceOperations.claim_next(context.worker.id, base)

    {:ok, operation} =
      ResourceOperations.mark_running(operation.id, operation.attempt_token, %{}, base)

    assert {:ok, _operation} =
             ResourceOperations.release_recovered(
               operation.id,
               operation.attempt_token,
               "wrapper disappeared",
               DateTime.add(base, 1, :second)
             )

    stats =
      ResourceOperations.statistics(
        worker_id: context.worker.id,
        from: DateTime.add(base, -1, :second),
        to: DateTime.add(base, 2, :second)
      )

    assert stats.count == 1
    assert stats.succeeded == 0
    assert stats.success_rate == 0.0
  end

  defp managed_run_fixture do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
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
        fencing_token: 1
      })

    %{repository: repository, job: job, worker: worker, run: run}
  end

  defp operation_attrs(context, invocation_id, extra \\ %{}) do
    Map.merge(
      %{
        worker_id: context.worker.id,
        repository_id: context.repository.id,
        job_id: context.job.id,
        agent_run_id: context.run.id,
        invocation_id: invocation_id,
        label: "test",
        priority: 10,
        state: "queued"
      },
      extra
    )
  end

  # A running operation whose wrapper went silent on a host that fences it.
  defp fenced_operation(invocation_id, record? \\ true) do
    context = managed_run_fixture()
    base = DateTime.add(DateTime.utc_now(), -60, :second)
    {:ok, _queued} = ResourceOperations.request(operation_attrs(context, invocation_id), base)
    {:ok, operation} = ResourceOperations.claim_next(context.worker.id, base)

    {:ok, operation} =
      ResourceOperations.mark_running(
        operation.id,
        operation.attempt_token,
        %{wrapper_pid: 999_999},
        base
      )

    assert ResourceOperations.mark_stale_recovery_pending() == 1
    operation = Repo.get!(ResourceOperation, operation.id)

    if record? do
      {:ok, operation} = ResourceOperations.record_fenced(operation, %{"processes" => []})
      operation
    else
      operation
    end
  end

  defp temporary_lock_directory do
    directory =
      Path.join(System.tmp_dir!(), "ptc-fence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    with_env(
      resource_operation_socket_path: Path.join(directory, "operations.sock"),
      resource_operation_wrapper: Path.expand("deploy/ptc-operation")
    )

    directory
  end

  defp with_env(settings) do
    for {key, value} <- settings do
      previous = Application.fetch_env(:ptc_manager, key)
      Application.put_env(:ptc_manager, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:ptc_manager, key, value)
          :error -> Application.delete_env(:ptc_manager, key)
        end
      end)
    end
  end

  defp hold_lock(path) do
    port =
      Port.open({:spawn_executable, "/usr/bin/python3"}, [
        :binary,
        args: [
          "-c",
          "import fcntl, sys, time; f = open(sys.argv[1], 'a'); fcntl.flock(f, fcntl.LOCK_EX); " <>
            "print('locked', flush=True); sys.stdin.read()",
          path
        ]
      ])

    assert_receive {^port, {:data, "locked\n"}}, 5_000
    port
  end

  defp wait_until_free(path, attempts \\ 50) do
    {output, 0} =
      System.cmd(
        "/usr/bin/python3",
        [
          "-c",
          "import fcntl, sys; f = open(sys.argv[1]); " <>
            "print('free' if not fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB) else '')",
          path
        ],
        stderr_to_stdout: true
      )
      |> then(fn {output, status} -> {String.trim(output), status} end)
      |> case do
        {"free", 0} = free -> free
        _held when attempts > 0 -> Process.sleep(50) && wait_until_free(path, attempts - 1)
      end

    output
  end

  # Started from inside Python so it runs the interpreter itself: macOS hides
  # the environment of its python3 shims.
  defp spawn_marked(marker) do
    {pid, 0} =
      System.cmd("/usr/bin/python3", [
        "-c",
        "import os, subprocess, sys; print(subprocess.Popen([sys.executable, '-c', " <>
          "'import time; time.sleep(30)'], env=dict(os.environ, PTC_OPERATION_ATTEMPT=sys.argv[1]), " <>
          "start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)",
        marker
      ])

    pid = String.trim(pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true) end)
    pid
  end

  defp set_operation_capacity(capacity) do
    setting = PtcManager.CapacitySettings.current()

    assert {:ok, _setting} =
             PtcManager.CapacitySettings.update(%{
               light_agent_capacity: setting.light_agent_capacity,
               heavy_agent_capacity: setting.heavy_agent_capacity,
               operation_capacity: capacity
             })
  end
end
