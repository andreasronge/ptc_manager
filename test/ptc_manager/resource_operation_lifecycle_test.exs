defmodule PtcManager.ResourceOperationLifecycleTest do
  # The real broker and the real wrapper on a temporary socket and the test
  # database; never the live console.
  use PtcManager.DataCase, async: false

  @moduletag resource_e2e: true

  alias PtcManager.{ManagedOperationContext, Operations, ResourceOperations}
  alias PtcManager.{ResourceOperationBroker, ResourceOperationRecovery}
  alias PtcManager.Operations.{Job, ResourceOperation}

  setup do
    root = Path.join(System.tmp_dir!(), "ptc-lifecycle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    socket = Path.join(root, "operations.sock")

    previous =
      for key <- [
            :resource_operation_socket_path,
            :resource_operation_wrapper,
            :execution_artifact_root
          ],
          do: {key, Application.get_env(:ptc_manager, key)}

    Application.put_env(:ptc_manager, :resource_operation_socket_path, socket)

    Application.put_env(
      :ptc_manager,
      :resource_operation_wrapper,
      Path.expand("deploy/ptc-operation")
    )

    Application.put_env(:ptc_manager, :execution_artifact_root, nil)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:ptc_manager, key, value) end)
      File.rm_rf!(root)
    end)

    start_broker(socket)
    %{root: root, socket: socket, owner: owner_fixture()}
  end

  test "a command runs through request, acquire, running, heartbeat and finish", context do
    {output, status} =
      run_wrapped(context, ["/usr/bin/python3", "-c", "import time; time.sleep(0.5)"])

    assert status == 0, output
    assert [%ResourceOperation{state: "completed", exit_status: 0}] = Repo.all(ResourceOperation)
  end

  test "a broker restart mid-run loses nothing", context do
    port = start_wrapped(context, ["/usr/bin/python3", "-c", "import time; time.sleep(2)"])
    wait_for_state("running")

    stop_supervised!(ResourceOperationBroker)
    Process.sleep(300)
    start_broker(context.socket)

    {output, status} = await_wrapper(port)
    assert status == 0, output
    assert [%ResourceOperation{state: "completed"}] = Repo.all(ResourceOperation)
  end

  test "a wrapper killed after running leaves a fenced operation a maintainer releases",
       context do
    port = start_wrapped(context, ["/usr/bin/python3", "-c", "import time; time.sleep(30)"])
    operation = wait_for_state("running")
    {:os_pid, wrapper} = Port.info(port, :os_pid)
    survivors = marked_pids(operation)

    on_exit(fn ->
      Enum.each(survivors, &System.cmd("kill", ["-KILL", &1], stderr_to_stdout: true))
    end)

    System.cmd("kill", ["-KILL", Integer.to_string(wrapper)])
    await_wrapper(port)

    fence(operation)
    fenced = Repo.get!(ResourceOperation, operation.id)
    assert fenced.state == "recovery_pending"
    assert fenced.fence_evidence["lock"] == "free"
    assert [%{"command" => command}] = fenced.fence_evidence["processes"]
    assert command =~ "time.sleep(30)"
    assert PtcManager.OperationalMode.mode() != :maintenance

    assert {:error, :processes_listed} =
             ResourceOperationRecovery.release(fenced, "maintainer", false)

    assert {:ok, %{state: "lost"}} = ResourceOperationRecovery.release(fenced, "maintainer", true)
  end

  test "a wrapper killed before running leaves nothing behind", context do
    PtcManager.CapacitySettings.update(%{
      light_agent_capacity: 2,
      heavy_agent_capacity: 1,
      operation_capacity: 1
    })

    holder = start_wrapped(context, ["/usr/bin/python3", "-c", "import time; time.sleep(3)"])
    wait_for_state("running")
    waiting = start_wrapped(context, ["/usr/bin/touch", Path.join(context.root, "must-not-run")])
    wait_for_state("queued")
    {:os_pid, pid} = Port.info(waiting, :os_pid)
    System.cmd("kill", ["-KILL", Integer.to_string(pid)])
    await_wrapper(waiting)

    later = DateTime.add(DateTime.utc_now(), 60, :second)
    assert ResourceOperations.expire_stale_queued(later) == 1
    assert {_output, 0} = await_wrapper(holder)
    refute File.exists?(Path.join(context.root, "must-not-run"))
  end

  test "a release cannot win against a paused wrapper that still holds its slot", context do
    port = start_wrapped(context, ["/usr/bin/python3", "-c", "import time; time.sleep(2)"])
    operation = wait_for_state("running")
    {:os_pid, wrapper} = Port.info(port, :os_pid)
    System.cmd("kill", ["-STOP", Integer.to_string(wrapper)])

    fence(operation)
    fenced = Repo.get!(ResourceOperation, operation.id)
    assert fenced.fence_evidence["lock"] == "held"

    assert {:error, {:slot_lock_held, ^wrapper}} =
             ResourceOperationRecovery.release(fenced, "maintainer", true)

    System.cmd("kill", ["-CONT", Integer.to_string(wrapper)])
    assert {_output, 0} = await_wrapper(port)
    assert Repo.get!(ResourceOperation, operation.id).state == "completed"
  end

  defp start_broker(socket) do
    start_supervised!({ResourceOperationBroker, name: :lifecycle_broker, path: socket},
      id: ResourceOperationBroker
    )
  end

  # A stale heartbeat moves the operation to recovery, and one sweep fences it.
  defp fence(operation) do
    later = DateTime.add(DateTime.utc_now(), 60, :second)
    assert ResourceOperations.mark_stale_recovery_pending(later) == 1
    ResourceOperationBroker.sweep()
    operation
  end

  defp run_wrapped(context, command), do: context |> start_wrapped(command) |> await_wrapper()

  defp start_wrapped(context, command) do
    {:ok, issued} =
      ManagedOperationContext.issue(context.owner, directory: Path.join(context.root, "contexts"))

    Port.open({:spawn_executable, Path.expand("deploy/ptc-operation")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["run", "--label", "test", "--" | command],
      env: [
        {~c"PTC_MANAGED_OPERATION_CONTEXT", String.to_charlist(issued.path)},
        {~c"PTC_OPERATION_POLL_SECONDS", ~c"0.05"},
        {~c"PTC_OPERATION_HEARTBEAT_SECONDS", ~c"0.2"}
      ]
    ])
  end

  defp await_wrapper(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> await_wrapper(port, output <> data)
      {^port, {:exit_status, status}} -> {output, status}
    after
      15_000 -> flunk("wrapper did not exit: #{output}")
    end
  end

  defp wait_for_state(state, attempts \\ 200) do
    case Repo.one(from o in ResourceOperation, where: o.state == ^state, limit: 1) do
      %ResourceOperation{} = operation ->
        operation

      nil when attempts > 0 ->
        Process.sleep(25)
        wait_for_state(state, attempts - 1)

      nil ->
        flunk("no operation reached #{state}")
    end
  end

  defp marked_pids(operation) do
    marker = "#{operation.id}-#{String.slice(operation.attempt_token, 0, 12)}"

    {output, 0} =
      System.cmd(Path.expand("deploy/ptc-operation"), [
        "inspect",
        "--marker",
        marker,
        "--lock",
        "/nonexistent"
      ])

    for process <- Jason.decode!(output)["processes"], do: Integer.to_string(process["pid"])
  end

  defp owner_fixture do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
    job = job |> Job.changeset(%{state: "working"}) |> Repo.update!()
    worker = worker_fixture(%{worker_incarnation_id: "lifecycle-worker"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now,
        herdr_pane: "lifecycle-pane",
        fencing_token: 1
      })

    %{
      owner_type: "job",
      owner_id: job.id,
      repository_id: repository.id,
      worker_id: worker.id,
      pane_id: "lifecycle-pane",
      fencing_token: 1
    }
  end
end
