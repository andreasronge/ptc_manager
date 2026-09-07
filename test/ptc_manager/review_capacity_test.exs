defmodule PtcManager.ReviewCapacityTest do
  use PtcManager.DataCase, async: false
  import PtcManager.OperationsFixtures
  alias PtcManager.{Operations, Repo, Reviews, Worktrees}
  alias PtcManager.Operations.{Job, AgentRun, WorktreeAllocation}

  defmodule ResumeAdapter do
    def resume_review_job(job) do
      send(Application.fetch_env!(:ptc_manager, :review_capacity_test_pid), {:resumed, job.id})
      {:ok, :resumed}
    end
  end

  defmodule UncertainAdapter do
    def resume_review_job(_job), do: {:error, :agent_launch_uncertain}
  end

  setup do
    keys = [:review_resume_adapter, :review_capacity_test_pid]
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
