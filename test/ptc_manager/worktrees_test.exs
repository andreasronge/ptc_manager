defmodule PtcManager.WorktreesTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{Job, WorktreeAllocation}
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

  test "reclaims the oldest safe worktree when all agent-derived slots are occupied" do
    {repository, first_job, first_remote} = approved_job_fixture()
    {_repository, second_job, second_remote} = approved_job_fixture(repository)
    {_repository, third_job, third_remote} = approved_job_fixture(repository)

    {:ok, first} =
      Operations.lease_job(first_job.id, "herdr:pool", first_remote, 60_000, capacity: 2)

    {:ok, _second} =
      Operations.lease_job(second_job.id, "herdr:pool", second_remote, 60_000, capacity: 2)

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
    assert_receive {:remove_worktree, allocation_id}
    assert allocation_id == allocation.id
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "removed"

    assert {:ok, _third} =
             Operations.lease_job(
               third_job.id,
               "herdr:pool",
               third_remote,
               60_000,
               capacity: 2
             )

    assert repository.id == third_job.repository_id
  end

  test "leaves new work queued when no occupied worktree is safe to remove" do
    {repository, first_job, first_remote} = approved_job_fixture()
    {_repository, second_job, _second_remote} = approved_job_fixture(repository)

    {:ok, _first} =
      Operations.lease_job(first_job.id, "herdr:pool", first_remote, 60_000, capacity: 1)

    assert {:error, :worktree_capacity} =
             Worktrees.ensure_slot("herdr:pool", 1, FakeAdapter, FakeProbe)

    refute_receive {:remove_worktree, _allocation_id}
    assert Repo.get!(Job, second_job.id).state == "queued"
  end

  test "does not reclaim a warm worktree before GitHub confirms its PR head" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = Operations.lease_job(job.id, "herdr:pool", remote, 60_000, capacity: 1)
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

  test "a cleanup failure preserves the worktree for attention" do
    {_repository, job, remote} = approved_job_fixture()

    {:ok, leased} =
      Operations.lease_job(job.id, "herdr:pool", remote, 60_000, capacity: 1)

    allocation = Repo.get_by!(WorktreeAllocation, job_id: leased.id)

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "reclaimable",
      herdr_workspace: "old-workspace",
      head_sha: String.duplicate("a", 40)
    })
    |> Repo.update!()

    Process.put(:worktree_remove_result, {:error, :workspace_busy})

    assert {:error, {:worktree_cleanup_failed, :workspace_busy}} =
             Worktrees.ensure_slot("herdr:pool", 1, FakeAdapter, FakeProbe)

    preserved = Repo.get!(WorktreeAllocation, allocation.id)
    assert preserved.state == "attention"
    assert preserved.last_error =~ "workspace_busy"
  end

  test "a terminal worktree is never removed when the final clean-head check fails" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = Operations.lease_job(job.id, "herdr:pool", remote, 60_000, capacity: 1)
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

  test "a stale concurrent cleanup cannot resurrect a removed allocation" do
    {_repository, job, remote} = approved_job_fixture()
    {:ok, leased} = Operations.lease_job(job.id, "herdr:pool", remote, 60_000, capacity: 1)
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
end
