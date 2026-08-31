defmodule PtcManager.WorktreesTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{Job, PrPublication, WorktreeAllocation}
  alias PtcManager.Repo
  alias PtcManager.Worktrees

  defmodule FakeAdapter do
    def remove_worktree(allocation) do
      send(Process.get(:worktree_test_pid), {:remove_worktree, allocation.id})
      Process.get(:worktree_remove_result, :ok)
    end
  end

  defmodule FakeProbe do
    def reclaimable(_path, _branch, _head), do: Process.get(:worktree_probe_result, :ok)
  end

  setup do
    Process.put(:worktree_test_pid, self())
    Process.put(:worktree_remove_result, :ok)
    Process.put(:worktree_probe_result, :ok)
    :ok
  end

  test "retains an open PR worktree without consuming an execution slot" do
    {repository, first_job, first_remote} = approved_job_fixture()
    {_repository, second_job, second_remote} = approved_job_fixture(repository)
    {_repository, third_job, third_remote} = approved_job_fixture(repository)

    {:ok, first} =
      lease_pool_job(first_job.id, first_remote, 2)

    {:ok, _second} =
      lease_pool_job(second_job.id, second_remote, 2)

    allocation = Repo.get_by!(WorktreeAllocation, job_id: first.id)

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "reclaimable",
      herdr_workspace: "old-workspace",
      head_sha: String.duplicate("a", 40)
    })
    |> Repo.update!()

    first |> Job.changeset(%{state: "pr_open"}) |> Repo.update!()

    assert :ok = Worktrees.ensure_slot("herdr:pool", 2, FakeAdapter, FakeProbe)
    refute_receive {:remove_worktree, _allocation_id}
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "reclaimable"

    assert {:ok, _third} =
             lease_pool_job(third_job.id, third_remote, 2)

    assert repository.id == third_job.repository_id
  end

  test "leaves new work queued when no occupied worktree is safe to remove" do
    {repository, first_job, first_remote} = approved_job_fixture()
    {_repository, second_job, _second_remote} = approved_job_fixture(repository)

    {:ok, _first} =
      lease_pool_job(first_job.id, first_remote, 1)

    assert {:error, :worktree_capacity} =
             Worktrees.ensure_slot("herdr:pool", 1, FakeAdapter, FakeProbe)

    refute_receive {:remove_worktree, _allocation_id}
    assert Repo.get!(Job, second_job.id).state == "queued"
  end

  test "does not reclaim a warm worktree before GitHub confirms its PR head" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = lease_pool_job(job.id, remote, 1)
    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "warm",
      herdr_workspace: "unconfirmed-workspace",
      head_sha: String.duplicate("a", 40)
    })
    |> Repo.update!()

    assert {:error, :worktree_capacity} =
             Worktrees.ensure_slot("herdr:pool", 1, FakeAdapter, FakeProbe)

    refute_receive {:remove_worktree, _allocation_id}
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "warm"
  end

  test "a terminal cleanup failure preserves the worktree for attention" do
    {_repository, job, remote} = approved_job_fixture()

    {:ok, leased} =
      lease_pool_job(job.id, remote, 1)

    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "terminal",
      herdr_workspace: "old-workspace",
      head_sha: String.duplicate("a", 40)
    })
    |> Repo.update!()

    Process.put(:worktree_remove_result, {:error, :workspace_busy})

    assert {:error, {:worktree_cleanup_failed, :workspace_busy}} =
             Worktrees.cleanup_terminal_once(FakeAdapter, FakeProbe)

    preserved = Repo.get!(WorktreeAllocation, allocation.id)
    assert preserved.state == "attention"
    assert preserved.last_error =~ "workspace_busy"
  end

  test "a PR repair reserves its retained worktree until verification finishes" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = lease_pool_job(job.id, remote, 1)
    head_sha = String.duplicate("a", 40)
    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{state: "reclaimable", head_sha: head_sha})
    |> Repo.update!()

    leased |> Job.changeset(%{state: "pr_open"}) |> Repo.update!()

    assert {:ok, reserved} = Operations.reserve_worktree_for_repair(leased.id, "repair-agent")
    assert reserved.state == "active"

    assert {:error, :worktree_capacity} =
             Worktrees.ensure_slot("herdr:pool", 1, FakeAdapter, FakeProbe)

    refute_receive {:remove_worktree, _allocation_id}

    assert {:ok, released} =
             Operations.release_repair_worktree(leased.id, head_sha, "repair-agent")

    assert released.state == "waiting"
  end

  test "a repair cannot start while the worker's only execution slot is busy" do
    {repository, active_job, active_remote} = approved_job_fixture()

    {:ok, _active} =
      lease_pool_job(active_job.id, active_remote, 1)

    {_repository, repair_job, _repair_remote} = approved_job_fixture(repository)
    worker = Repo.get_by!(PtcManager.Operations.Worker, worker_key: "herdr:pool")

    repair_job
    |> Job.changeset(%{
      state: "pr_open",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      branch_name: "ptc/repair"
    })
    |> Repo.update!()

    %WorktreeAllocation{}
    |> WorktreeAllocation.changeset(%{
      worker_id: worker.id,
      job_id: repair_job.id,
      state: "waiting",
      path: "/tmp/repair-waiting",
      last_used_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:error, :dispatch_capacity} =
             Operations.reserve_worktree_for_repair(repair_job.id)

    assert Repo.get_by!(WorktreeAllocation, job_id: repair_job.id).state == "waiting"
  end

  test "an active repair prevents a new implementation lease on the same slot" do
    worker =
      worker_fixture(%{
        worker_key: "herdr:pool",
        capabilities: %{"herdr" => true, "implementation_slots" => 1}
      })

    {repository, repair_job, _repair_remote} = approved_job_fixture()

    repair_job
    |> Job.changeset(%{
      state: "pr_open",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      branch_name: "ptc/repair"
    })
    |> Repo.update!()

    %WorktreeAllocation{}
    |> WorktreeAllocation.changeset(%{
      worker_id: worker.id,
      job_id: repair_job.id,
      state: "waiting",
      path: "/tmp/repair-active",
      last_used_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, reserved} = Operations.reserve_worktree_for_repair(repair_job.id)
    assert reserved.state == "active"

    {_repository, next_job, next_remote} = approved_job_fixture(repository)

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(next_job.id, worker.worker_key, next_remote, 60_000,
               capacity: 1
             )

    assert Repo.get!(Job, next_job.id).state == "queued"
  end

  test "a terminal worktree is never removed when the final clean-head check fails" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = lease_pool_job(job.id, remote, 1)
    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "terminal",
      herdr_workspace: "dirty-workspace",
      head_sha: String.duplicate("a", 40)
    })
    |> Repo.update!()

    Process.put(:worktree_probe_result, {:error, :worktree_dirty})

    assert {:error, {:worktree_cleanup_failed, :worktree_dirty}} =
             Worktrees.cleanup_terminal_once(FakeAdapter, FakeProbe)

    refute_receive {:remove_worktree, _allocation_id}
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "attention"
  end

  test "a merged PR removes its retained worktree even when the checkout is dirty" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = lease_pool_job(job.id, remote, 1)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    head_sha = String.duplicate("a", 40)

    leased
    |> Job.changeset(%{state: "done", ended_at: now, branch_name: "ptc/merged"})
    |> Repo.update!()

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: leased.id,
      state: "published",
      idempotency_key: String.duplicate("b", 64),
      fencing_token: leased.fencing_token,
      branch_name: "ptc/merged",
      base_sha: String.duplicate("c", 40),
      head_sha: head_sha,
      diff_digest: String.duplicate("d", 64),
      attempt_count: 1,
      pr_number: 42,
      pr_url: "https://github.com/example/repo/pull/42",
      remote_head_sha: head_sha,
      published_at: now,
      pr_state: "merged",
      pr_checked_at: now
    })
    |> Repo.insert!()

    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "terminal",
      herdr_workspace: "merged-workspace",
      head_sha: head_sha
    })
    |> Repo.update!()

    Process.put(:worktree_probe_result, {:error, :worktree_dirty})

    assert :ok = Worktrees.cleanup_terminal_once(FakeAdapter, FakeProbe)
    assert_receive {:remove_worktree, allocation_id}
    assert allocation_id == allocation.id
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "removed"
  end

  test "a stale concurrent cleanup cannot resurrect a removed allocation" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = lease_pool_job(job.id, remote, 1)
    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{state: "terminal", head_sha: String.duplicate("a", 40)})
    |> Repo.update!()

    assert {:ok, _claimed, token} = Operations.claim_worktree_cleanup(allocation.id)

    assert {:error, :worktree_cleanup_already_claimed} =
             Operations.claim_worktree_cleanup(allocation.id)

    assert {:ok, removed} = Operations.complete_worktree_cleanup(allocation.id, token)
    assert removed.state == "removed"

    assert {:error, :stale_worktree_cleanup_claim} =
             Operations.fail_worktree_cleanup(allocation.id, token, :already_missing)

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "removed"
  end

  defp approved_job_fixture(repository \\ nil) do
    repository = repository || repository_fixture(%{local_path: "/tmp/repository"})
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    remote = %{
      state: "open",
      content_digest: issue.content_digest,
      github_updated_at: issue.github_updated_at,
      blocking_issue_numbers: [],
      dependency_overflow: false
    }

    {repository, job, remote}
  end

  defp lease_pool_job(job_id, remote, capacity) do
    Repo.get_by(PtcManager.Operations.Worker, worker_key: "herdr:pool") ||
      worker_fixture(%{
        worker_key: "herdr:pool",
        capabilities: %{"herdr" => true, "implementation_slots" => capacity}
      })

    Operations.lease_job(job_id, "herdr:pool", remote, 60_000, capacity: capacity)
  end
end
