defmodule PtcManager.DemoSeedTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations.{AgentRun, Issue, Job, Repository, WorktreeAllocation}
  alias PtcManager.Repo

  setup do
    previous = Application.get_env(:ptc_manager, :demo_mode)
    Application.put_env(:ptc_manager, :demo_mode, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ptc_manager, :demo_mode)
      else
        Application.put_env(:ptc_manager, :demo_mode, previous)
      end
    end)
  end

  test "the browser demo represents one consistent active workflow" do
    Code.eval_file("priv/repo/seeds.exs")

    assert Repo.aggregate(Repository, :count) == 1
    assert Repo.aggregate(Issue, :count) == 3
    assert Repo.aggregate(AgentRun, :count) == 2

    job = Repo.one!(Job)
    repository = Repo.one!(Repository)
    allocation = Repo.one!(WorktreeAllocation)

    assert is_nil(repository.local_path)
    assert repository.required_pre_pr_reviews == 2

    assert job.state == "working"
    assert job.fencing_token == 1
    assert job.lease_owner == "hetzner-primary"
    assert DateTime.compare(job.lease_expires_at, DateTime.utc_now()) == :gt
    assert job.branch_name == "ptc-manager/issue-1320-job-#{job.id}"
    assert allocation.job_id == job.id
    assert allocation.state == "active"

    assert Repo.one!(PtcManager.Operations.Worker).capabilities["implementation_slots"] == 1

    assert Repo.get_by!(AgentRun, job_id: job.id).fencing_token == job.fencing_token
  end
end
