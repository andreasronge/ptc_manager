defmodule PtcManager.ResourceOperationsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.ResourceOperation
  alias PtcManager.Repo
  alias PtcManager.ResourceOperations

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
