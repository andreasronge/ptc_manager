defmodule PtcManager.ReviewCapacityTest do
  use PtcManager.DataCase, async: false
  import PtcManager.OperationsFixtures
  alias PtcManager.{Operations, Repo, Reviews, Worktrees}
  alias PtcManager.Operations.{Job, AgentRun, WorktreeAllocation}

  defmodule ResumeAdapter do
    def stop_review_agent(_, true), do: :ok
    def stop_review_agent(_), do: :ok

    def resume_review_job(job) do
      send(Application.fetch_env!(:ptc_manager, :review_capacity_test_pid), {:resumed, job.id})
      {:ok, :resumed}
    end
  end

  defmodule TransientStopAdapter do
    def stop_review_agent(_, true), do: Process.get(:stop_result, {:error, :offline})
    def discard_worktree(_), do: :ok
  end

  defmodule FailedPaneClose do
    def close_pane(_), do: {:error, :offline}
  end

  defmodule BusyAdapter do
    def stop_review_agent(_), do: {:error, :retained_agent_busy}
    def resume_review_job(_), do: raise("must not launch")
  end

  defmodule CompletedDuringLaunchAdapter do
    def stop_review_agent(_), do: :ok

    def resume_review_job(job) do
      job |> Job.changeset(%{state: "done"}) |> Repo.update!()
      {:ok, :completed}
    end
  end

  defmodule FailedSnapshotCleanup do
    def release_review_owned(_, _), do: {:error, :cleanup_temporarily_unavailable}
  end

  defmodule BeforeLaunchFailureAdapter do
    def stop_review_agent(_), do: :ok

    def resume_review_job(_),
      do:
        {:error,
         {:continuation_not_started,
          Process.get(:prelaunch_failure, :retained_workspace_not_ready)}}
  end

  defmodule UncertainAdapter do
    def stop_review_agent(_), do: :ok
    def resume_review_job(_job), do: {:error, :agent_launch_uncertain}
  end

  setup do
    keys = [
      :review_resume_adapter,
      :review_capacity_test_pid,
      :planning_snapshot_root,
      :herdr_client
    ]

    old = Map.new(keys, &{&1, Application.fetch_env(:ptc_manager, &1)})

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:ptc_manager, key, value)
          :error -> Application.delete_env(:ptc_manager, key)
        end
      end
    end)

    Application.put_env(:ptc_manager, :review_resume_adapter, ResumeAdapter)
    Application.put_env(:ptc_manager, :review_capacity_test_pid, self())
    worker = worker_fixture(%{capabilities: %{"herdr" => true, "implementation_slots" => 1}})
    %{worker: worker}
  end

  defp queued_job do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 2, "standard")
    {job, issue}
  end

  defp paused_job(worker, review_state \\ "paused") do
    {job, _} = queued_job()

    job =
      job
      |> Job.changeset(%{
        state: "blocked",
        review_state: review_state,
        fencing_token: 1,
        lease_owner: worker.worker_key,
        branch_name: "retained-#{job.id}"
      })
      |> Repo.update!()

    %WorktreeAllocation{}
    |> WorktreeAllocation.changeset(%{
      job_id: job.id,
      worker_id: worker.id,
      state: "active",
      last_used_at: DateTime.utc_now(),
      path: "/tmp/retained-review-#{job.id}"
    })
    |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        job_id: job.id,
        worker_id: worker.id,
        role: "implementer",
        state: "done",
        started_at: DateTime.utc_now(),
        last_heartbeat_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now(),
        fencing_token: 1,
        agent_name: "retained-#{job.id}"
      })

    {job, run}
  end

  test "failed cancellation retries and confirmed cancellation permits explicit discard", %{
    worker: worker
  } do
    {job, run} = paused_job(worker)
    run |> AgentRun.changeset(%{state: "working", ended_at: nil}) |> Repo.update!()
    {:ok, cancelled} = Reviews.decide(job.id, 0, "cancel", %{"reason" => "Stop"}, "maintainer")
    Application.put_env(:ptc_manager, :review_resume_adapter, TransientStopAdapter)
    args = %Oban.Job{args: %{"job_id" => job.id, "generation" => cancelled.review_generation}}
    allocation = Repo.get_by!(WorktreeAllocation, job_id: job.id)
    allocation |> WorktreeAllocation.changeset(%{state: "attention"}) |> Repo.update!()
    assert {:snooze, 30} = PtcManager.Reviews.CancelWorker.perform(args)
    assert Repo.get!(AgentRun, run.id).state == "working"

    assert {:error, :worktree_in_use} =
             Worktrees.discard_attention(allocation.id, "maintainer", TransientStopAdapter)

    Process.put(:stop_result, :ok)
    assert :ok = PtcManager.Reviews.CancelWorker.perform(args)
    assert Repo.get!(AgentRun, run.id).state == "lost"
    assert Reviews.held?(Repo.get!(Job, job.id))
    assert :ok = Worktrees.discard_attention(allocation.id, "maintainer", TransientStopAdapter)
  end

  test "cancellation waits for a reserved launch and then durably stops it", %{worker: worker} do
    {job, run} = paused_job(worker)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    {:ok, reserved} = Operations.claim_review_continuation(job.id, pending.review_generation)

    {:ok, cancelled} =
      Reviews.decide(
        job.id,
        pending.review_generation,
        "cancel",
        %{"reason" => "Stop this work"},
        "maintainer"
      )

    args = %Oban.Job{args: %{"job_id" => job.id, "generation" => cancelled.review_generation}}
    assert {:snooze, 10} = PtcManager.Reviews.CancelWorker.perform(args)
    assert Repo.get!(AgentRun, run.id).state == "done"

    cancelled
    |> Job.changeset(%{review_resume_expires_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()

    assert :ok = PtcManager.Reviews.CancelWorker.perform(args)
    assert Repo.get!(AgentRun, run.id).state == "lost"
    assert is_nil(Repo.get!(Job, job.id).review_resume_expires_at)

    assert {:error, :stale_continuation} =
             PtcManager.Reviews.Launch.reserve(
               reserved,
               run,
               "new-pane",
               "workspace",
               "codex",
               "new-agent"
             )
  end

  test "launch identity is persisted before any external agent can start", %{worker: worker} do
    {job, run} = paused_job(worker)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    {:ok, reserved} = Operations.claim_review_continuation(job.id, pending.review_generation)

    assert {:ok, owned} =
             PtcManager.Reviews.Launch.reserve(
               reserved,
               run,
               "new-pane",
               "workspace",
               "codex",
               "new-agent"
             )

    assert owned.state == "starting"
    assert owned.agent_name == "new-agent"
    assert owned.herdr_pane == "new-pane"
    assert owned.external_key == nil
  end

  test "general Cancel agent uses durable cleanup during a reserved launch", %{worker: worker} do
    {job, run} = paused_job(worker)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    {:ok, reserved} = Operations.claim_review_continuation(job.id, pending.review_generation)

    {:ok, _} =
      PtcManager.Reviews.Launch.reserve(
        reserved,
        run,
        "new-pane",
        "workspace",
        "codex",
        "new-agent"
      )

    Application.put_env(:ptc_manager, :herdr_client, FailedPaneClose)

    assert {:ok, cancelled, {:pane_close_failed, :offline}} =
             Operations.cancel_running_job(job.id, "maintainer")

    assert cancelled.review_state == "cancelled"
    assert cancelled.review_generation == pending.review_generation + 1
    assert Repo.get!(AgentRun, run.id).state == "starting"

    cancelled
    |> Job.changeset(%{review_resume_expires_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()

    assert :ok =
             PtcManager.Reviews.CancelWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => cancelled.review_generation}
             })

    assert Repo.get!(AgentRun, run.id).state == "lost"
  end

  test "manual stop from reconciling releases confirmed stopped capacity", %{worker: worker} do
    {job, _} = paused_job(worker)
    job |> Job.changeset(%{state: "reconciling"}) |> Repo.update!()
    {:ok, manual} = Reviews.decide(job.id, 0, "manual", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.CancelWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => manual.review_generation}
             })

    current = Repo.get!(Job, job.id) |> Repo.preload(:agent_runs)
    assert Operations.review_capacity_released?(current)
  end

  test "recovering current agent never declares an older live identity stopped", %{worker: worker} do
    {job, current} = paused_job(worker)
    job |> Job.changeset(%{fencing_token: 2}) |> Repo.update!()
    current |> AgentRun.changeset(%{fencing_token: 2}) |> Repo.update!()

    {:ok, old} =
      Operations.create_agent_run(%{
        job_id: job.id,
        worker_id: worker.id,
        role: "implementer",
        state: "working",
        fencing_token: 1,
        started_at: DateTime.utc_now(),
        last_heartbeat_at: DateTime.utc_now(),
        agent_name: "old-live-identity"
      })

    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    assert Repo.get!(AgentRun, old.id).state == "working"
    assert Repo.get!(Job, job.id).review_state == "paused"
    refute_received {:resumed, _}
  end

  test "late recovery cannot reopen a completed job", %{worker: worker} do
    {job, _} = paused_job(worker)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    pending |> Job.changeset(%{state: "done"}) |> Repo.update!()

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    assert Repo.get!(Job, job.id).state == "done"
    refute_received {:resumed, _}
  end

  test "launch completion cannot reopen a job completed during dispatch", %{worker: worker} do
    {job, _} = paused_job(worker)
    Application.put_env(:ptc_manager, :review_resume_adapter, CompletedDuringLaunchAdapter)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    assert Repo.get!(Job, job.id).state == "done"
  end

  test "an idle terminal identity is reconciled before a queued continuation claims capacity", %{
    worker: worker
  } do
    {job, _} = paused_job(worker)
    job |> Job.changeset(%{state: "reconciling"}) |> Repo.update!()
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    assert_received {:resumed, id}
    assert id == job.id
    assert Repo.get!(Job, id).state == "working"
  end

  test "an active retained identity pauses instead of looping or starting another writer", %{
    worker: worker
  } do
    {job, _} = paused_job(worker)
    Application.put_env(:ptc_manager, :review_resume_adapter, BusyAdapter)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    current = Repo.get!(Job, job.id)
    assert current.review_state == "paused"
    assert current.review_resume_expires_at == nil
    assert current.review_recovery_expires_at == nil
    assert current.last_error =~ "could not be confirmed stopped"
    refute_received {:resumed, _}
  end

  test "a stale manual stop cannot close a newer continuation", %{worker: worker} do
    {job, _} = paused_job(worker)
    {:ok, manual} = Reviews.decide(job.id, 0, "manual", %{}, "maintainer")

    {:ok, pending} =
      Reviews.decide(job.id, manual.review_generation, "continue", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.CancelWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => manual.review_generation}
             })

    assert Repo.get!(Job, job.id).review_generation == pending.review_generation

    assert {:error, :review_decision_stale} =
             Reviews.decide(job.id, pending.review_generation, "continue", %{}, "maintainer")
  end

  @tag :nightly
  test "retry assesses retained commits before publication and later edits require a new assessment",
       %{worker: worker} do
    {job, _run} = paused_job(worker)

    job =
      job
      |> Job.changeset(%{branch_name: "ptc-manager/issue-123-job-#{job.id}"})
      |> Repo.update!()

    root = Path.join(System.tmp_dir!(), "review-lifecycle-#{System.unique_integer([:positive])}")
    workspace = PtcManager.TestGitWorkspace.new!(root)
    on_exit(fn -> File.rm_rf(root) end)

    git = fn args ->
      {output, 0} = System.cmd("git", ["-C", workspace.repository | args], stderr_to_stdout: true)
      String.trim(output)
    end

    git.(["switch", "-c", job.branch_name])
    File.write!(Path.join(workspace.repository, "implementation.txt"), "first implementation")
    git.(["add", "."])
    git.(["commit", "-m", "implementation"])
    repo = Repo.get!(PtcManager.Operations.Repository, job.repository_id)
    repo |> Ecto.Changeset.change(local_path: workspace.repository) |> Repo.update!()

    Repo.get_by!(WorktreeAllocation, job_id: job.id)
    |> WorktreeAllocation.changeset(%{path: workspace.repository})
    |> Repo.update!()

    job |> Job.changeset(%{review_state: "pending"}) |> Repo.update!()
    {:ok, failed} = Reviews.request(job.id, 1, "first")
    assert failed.state == "queued", inspect(failed.error)
    Application.put_env(:ptc_manager, :planning_snapshot_root, Path.join(root, "snapshots"))
    {:ok, running} = Reviews.claim(failed.id)

    {:ok, snapshot} =
      PtcManager.Reviews.Snapshots.prepare(
        running,
        Repo.get!(PtcManager.Operations.Repository, job.repository_id)
      )

    assert {:error, :cleanup_temporarily_unavailable} =
             PtcManager.Reviews.Snapshots.cleanup(failed.id, FailedSnapshotCleanup)

    assert Repo.get!(PtcManager.Reviews.Round, failed.id).input["snapshot_cleanup_error"]

    assert {:ok, :ok} =
             Reviews.fail(failed.id, {:reviewer_command_failed, 1, "provider unavailable"})

    # Simulate losing the reviewer process before its after block runs.
    Reviews.sweep()

    assert Repo.exists?(
             from o in Oban.Job, where: o.worker == "PtcManager.Reviews.SnapshotCleanupWorker"
           )

    assert :ok =
             PtcManager.Reviews.SnapshotCleanupWorker.perform(%Oban.Job{
               args: %{"round_id" => failed.id}
             })

    refute File.exists?(snapshot.path)
    assert Repo.get!(PtcManager.Reviews.Round, failed.id).input["source_snapshot"] == nil
    {:ok, pending} = Reviews.decide(job.id, 0, "retry_review", %{}, "maintainer")
    args = %Oban.Job{args: %{"job_id" => job.id, "generation" => pending.review_generation}}

    Repo.query!(
      "CREATE TEMP TRIGGER busy_review_preparation BEFORE UPDATE OF state ON review_rounds WHEN NEW.state = 'queued' BEGIN SELECT RAISE(ABORT, 'Database busy'); END"
    )

    try do
      assert :ok = PtcManager.Reviews.ResumeWorker.perform(args)
      assert List.last(Reviews.rounds(job.id)).state == "preparing"
    after
      Repo.query!("DROP TRIGGER busy_review_preparation")
    end

    preparation = List.last(Reviews.rounds(job.id))

    assert Repo.exists?(
             from o in Oban.Job,
               where:
                 o.worker == "PtcManager.Reviews.PrepareWorker" and
                   o.args == ^%{"round_id" => preparation.id}
           )

    assert {:ok, replay} = Reviews.request(job.id, 1, "retry-#{pending.review_generation}")
    assert replay.id == preparation.id

    assert :ok =
             PtcManager.Reviews.PrepareWorker.perform(%Oban.Job{
               args: %{"round_id" => preparation.id}
             })

    refute_received {:resumed, _}
    retry = List.last(Reviews.rounds(job.id))
    assert retry.state == "queued", inspect(retry.error)
    assert retry.head_sha == failed.head_sha

    assert Operations.review_capacity_released?(
             Repo.get!(Job, job.id)
             |> Repo.preload(:agent_runs)
           )

    assert {:ok, _} = Reviews.complete(retry.id, %{"summary" => "No bugs", "findings" => []})
    assert :ok = PtcManager.Reviews.ResumeWorker.perform(args)
    assert_received {:resumed, _}
    current = Repo.get!(Job, job.id)
    assert current.review_state == "passed"
    assert current.review_resume_expires_at == nil

    evidence = %{
      head_sha: retry.head_sha,
      base_sha: retry.base_sha,
      diff_digest: retry.diff_digest
    }

    assert Reviews.publication_allowed?(current, evidence)
    File.write!(Path.join(workspace.repository, "implementation.txt"), "mandatory validation fix")
    git.(["commit", "-am", "fix validation"])

    refute Reviews.publication_allowed?(current, %{
             evidence
             | head_sha: git.(["rev-parse", "HEAD"])
           })

    {:ok, next} = Reviews.request(job.id, 1, "changed-head")
    assert next.head_sha != retry.head_sha

    assert {:ok, _} =
             Reviews.complete(next.id, %{
               "summary" => "Bug",
               "findings" => [%{"severity" => "high", "description" => "Fix validation"}]
             })

    assert Repo.get!(Job, job.id).review_state == "paused"
  end

  test "stopped review holds release both capacity gates without removing the worktree", %{
    worker: worker
  } do
    for state <- ~w(paused manual) do
      {paused, _run} = paused_job(worker, state)

      [allocation] =
        Operations.list_occupying_worktrees(worker.worker_key)
        |> Enum.filter(&(&1.job_id == paused.id))

      refute Operations.worktree_consumes_execution_slot?(allocation)
      allocation |> WorktreeAllocation.changeset(%{state: "attention"}) |> Repo.update!()
      assert {:error, :worktree_in_use} = Worktrees.discard_attention(allocation.id, "maintainer")
      assert :ok = Worktrees.ensure_slot(worker.worker_key, 1, nil)
    end

    {queued, issue} = queued_job()

    assert {:ok, _} =
             Operations.lease_job(
               queued.id,
               worker.worker_key,
               Map.put(Map.from_struct(issue), :blocking_issues, []),
               60_000
             )
  end

  test "live, unknown, unobserved and unreconciled agents still occupy capacity", %{
    worker: worker
  } do
    {job, run} = paused_job(worker)

    for state <- ~w(working idle blocked unknown waiting) do
      Repo.get!(AgentRun, run.id)
      |> AgentRun.changeset(%{state: state, ended_at: nil})
      |> Repo.update!()

      assert {:error, :worktree_capacity} = Worktrees.ensure_slot(worker.worker_key, 1, nil)
    end

    Repo.get!(AgentRun, run.id)
    |> AgentRun.changeset(%{state: "done", ended_at: DateTime.utc_now()})
    |> Repo.update!()

    job |> Job.changeset(%{state: "reconciling"}) |> Repo.update!()
    assert {:error, :worktree_capacity} = Worktrees.ensure_slot(worker.worker_key, 1, nil)
    Repo.get!(Job, job.id) |> Job.changeset(%{state: "blocked"}) |> Repo.update!()
    Repo.delete!(Repo.get!(AgentRun, run.id))
    assert {:error, :worktree_capacity} = Worktrees.ensure_slot(worker.worker_key, 1, nil)
  end

  test "continuation waits for capacity then reserves it exactly once", %{worker: worker} do
    {paused, _run} = paused_job(worker)
    {busy, issue} = queued_job()

    assert {:ok, busy} =
             Operations.lease_job(
               busy.id,
               worker.worker_key,
               Map.put(Map.from_struct(issue), :blocking_issues, []),
               60_000
             )

    {:ok, pending} = Reviews.decide(paused.id, 0, "continue", %{}, "maintainer")
    assert is_nil(pending.review_resume_expires_at)
    args = %Oban.Job{args: %{"job_id" => paused.id, "generation" => pending.review_generation}}
    assert {:snooze, 10} = PtcManager.Reviews.ResumeWorker.perform(args)
    refute_received {:resumed, _}
    assert Repo.get!(Job, paused.id).review_state == "resume_pending"
    Reviews.sweep()
    assert Repo.get!(Job, paused.id).review_state == "resume_pending"

    busy |> Job.changeset(%{state: "done"}) |> Repo.update!()

    Repo.get_by!(WorktreeAllocation, job_id: busy.id)
    |> WorktreeAllocation.changeset(%{state: "removed"})
    |> Repo.update!()

    assert :ok = PtcManager.Reviews.ResumeWorker.perform(args)
    assert_received {:resumed, id}
    assert id == paused.id
    assert :ok = PtcManager.Reviews.ResumeWorker.perform(args)
    refute_received {:resumed, _}
    assert {:error, :worktree_capacity} = Worktrees.ensure_slot(worker.worker_key, 1, nil)
  end

  test "a pre-launch failure releases confirmed stopped capacity and can be continued", %{
    worker: worker
  } do
    {job, _} = paused_job(worker)
    job |> Job.changeset(%{state: "reconciling"}) |> Repo.update!()
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    Application.put_env(:ptc_manager, :review_resume_adapter, BeforeLaunchFailureAdapter)

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    current = Repo.get!(Job, job.id)
    assert current.state == "blocked"
    assert current.review_state == "paused"
    assert current.last_error =~ "retained_workspace_not_ready"
    assert :ok = Worktrees.ensure_slot(worker.worker_key, 1, nil)
    Application.put_env(:ptc_manager, :review_resume_adapter, ResumeAdapter)
    {:ok, next} = Reviews.decide(job.id, current.review_generation, "continue", %{}, "maintainer")

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => next.review_generation}
             })

    assert_received {:resumed, id}
    assert id == job.id
  end

  test "continuation failure exposes the native code without raw command output", %{
    worker: worker
  } do
    {job, _} = paused_job(worker)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    Application.put_env(:ptc_manager, :review_resume_adapter, BeforeLaunchFailureAdapter)

    Process.put(
      :prelaunch_failure,
      {:herdr_exit, 1,
       Jason.encode!(%{error: %{code: "linked_worktree_source", message: "private raw output"}})}
    )

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    error = Repo.get!(Job, job.id).last_error
    assert error =~ "linked_worktree_source"
    refute error =~ "private raw output"
  end

  test "an uncertain continuation keeps its reservation for reconciliation", %{worker: worker} do
    {job, _} = paused_job(worker)
    {:ok, pending} = Reviews.decide(job.id, 0, "continue", %{}, "maintainer")
    Application.put_env(:ptc_manager, :review_resume_adapter, UncertainAdapter)

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => pending.review_generation}
             })

    assert Repo.get!(Job, job.id).state == "reconciling"
    assert {:error, :worktree_capacity} = Worktrees.ensure_slot(worker.worker_key, 1, nil)
  end

  test "a claimed continuation excludes another contender and retains capacity on expiry", %{
    worker: worker
  } do
    {first, _} = paused_job(worker)
    {second, _} = paused_job(worker)
    {:ok, first} = Reviews.decide(first.id, 0, "continue", %{}, "maintainer")
    {:ok, second} = Reviews.decide(second.id, 0, "continue", %{}, "maintainer")

    assert {:ok, reserved} =
             Operations.claim_review_continuation(first.id, first.review_generation)

    assert reserved.review_resume_expires_at

    assert {:error, :continuation_already_claimed} =
             Operations.claim_review_continuation(first.id, first.review_generation)

    assert {:error, :dispatch_capacity} =
             Operations.claim_review_continuation(second.id, second.review_generation)

    reserved
    |> Job.changeset(%{review_resume_expires_at: DateTime.add(DateTime.utc_now(), -1)})
    |> Repo.update!()

    Reviews.sweep()
    assert Repo.get!(Job, first.id).state == "reconciling"
    assert {:error, :worktree_capacity} = Worktrees.ensure_slot(worker.worker_key, 1, nil)
  end
end
