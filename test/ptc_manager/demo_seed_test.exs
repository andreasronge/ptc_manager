defmodule PtcManager.DemoSeedTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations.{
    AgentRun,
    Issue,
    Job,
    PrPublication,
    Repository,
    ResourceOperation,
    WorktreeAllocation
  }

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
    assert Repo.aggregate(Issue, :count) == 8
    assert Repo.aggregate(AgentRun, :count) == 2
    assert Repo.aggregate(ResourceOperation, :count) == 6
    assert Repo.get_by!(ResourceOperation, state: "running").label == "test"

    # Every issue carries the ages, author, and labels Planning groups by.
    assert Enum.all?(Repo.all(Issue), & &1.github_created_at)
    assert Repo.get_by!(Issue, number: 1314).github_author_login == "an-outside-reporter"
    assert Repo.get_by!(Issue, number: 1331).github_labels == %{"names" => ["wait", "ux"]}
    assert Repo.one!(Repository).github_viewer_login == "andreasronge"

    # One merged pull request the agent labelled as having unfinished business.
    follow_up = Repo.get_by!(PrPublication, pr_number: 1_311)
    assert follow_up.pr_state == "merged"
    assert PrPublication.follow_up_suggested?(follow_up)

    job = Repo.get_by!(Job, state: "working")
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
