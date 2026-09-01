defmodule PtcManager.ResourceOperationBrokerTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.ManagedOperationContext
  alias PtcManager.Operations
  alias PtcManager.Operations.ResourceOperation
  alias PtcManager.Operations.Job
  alias PtcManager.Repo
  alias PtcManager.ResourceOperationBroker

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
    assert command =~ "PTC_OPERATION_CONTEXT_READY:"
    File.rm_rf!(directory)
  end

  test "terminal owner contexts are removed without touching active contexts" do
    directory =
      Path.join(System.tmp_dir!(), "ptc-context-cleanup-#{System.unique_integer([:positive])}")

    {:ok, active} =
      ManagedOperationContext.issue(%{owner_type: "job", owner_id: 10}, directory: directory)

    {:ok, terminal} =
      ManagedOperationContext.issue(%{owner_type: "job", owner_id: 20}, directory: directory)

    assert :ok =
             ManagedOperationContext.cleanup_inactive(
               &(&1["owner_id"] == 10),
               directory
             )

    assert File.exists?(active.path)
    refute File.exists?(terminal.path)
    File.rm_rf!(directory)
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

    %{repository: repository, job: job, worker: worker, run: run}
  end
end
