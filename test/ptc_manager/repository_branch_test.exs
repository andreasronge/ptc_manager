defmodule PtcManager.RepositoryBranchTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{AuditEvent, Job, PrPublication, Repository}
  alias PtcManager.Repo

  describe "update_repository_branch/3" do
    test "trims the name, records who changed it, and leaves GitHub's value alone" do
      repository = repository_fixture(%{github_default_branch: "develop"})

      assert {:ok, updated} =
               Operations.update_repository_branch(repository.id, " develop \n", "andreas")

      assert updated.default_branch == "develop"
      assert updated.github_default_branch == "develop"

      audit = Repo.get_by!(AuditEvent, action: "repository.default_branch_changed")
      assert audit.actor == "andreas"
      assert audit.details["from"] == "main"
      assert audit.details["to"] == "develop"
    end

    test "refuses a name the broker would refuse" do
      repository = repository_fixture()

      for branch <- ["", "-x", "a..b", "feature/", "x@{1}", "has space", nil] do
        assert {:error, :invalid_branch} =
                 Operations.update_repository_branch(repository.id, branch, "andreas")
      end

      assert Repo.get!(Repository, repository.id).default_branch == "main"
    end

    test "refuses while a job is active" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      {:ok, _job} = Operations.approve_issue_directly(issue.id, "andreas")

      assert {:error, :active_work} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")

      assert Repo.get!(Repository, repository.id).default_branch == "main"
    end

    test "refuses while a managed pull request is open, and allows it once merged" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      job = job |> Job.changeset(%{state: "done"}) |> Repo.update!()
      Repo.update_all(PtcManager.Automations.Invocation, set: [state: "succeeded"])
      publication = open_publication!(job)

      assert {:error, :active_work} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")

      publication |> PrPublication.changeset(%{pr_state: "merged"}) |> Repo.update!()

      assert {:ok, %{default_branch: "develop"}} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")
    end

    test "refuses while a maintainer action is queued" do
      repository = repository_fixture()

      assert {:ok, _action} =
               Operations.enqueue_agent_action(%{
                 repository_id: repository.id,
                 action_key: "prepare_issue",
                 target_type: "repository",
                 target_id: repository.id,
                 target_label: "Repository",
                 prompt_version: 1,
                 prompt: "Inspect",
                 actor: "andreas",
                 requested_at: DateTime.utc_now()
               })

      assert {:error, :active_work} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")
    end

    test "refuses while a job's worktree is retained, since it can be resumed" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      job |> Job.changeset(%{state: "failed"}) |> Repo.update!()
      Repo.update_all(PtcManager.Automations.Invocation, set: [state: "failed"])

      allocation =
        %PtcManager.Operations.WorktreeAllocation{}
        |> PtcManager.Operations.WorktreeAllocation.changeset(%{
          worker_id: worker_fixture().id,
          job_id: job.id,
          state: "reclaimable",
          path: System.tmp_dir!(),
          last_used_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      assert {:error, :active_work} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")

      allocation
      |> PtcManager.Operations.WorktreeAllocation.changeset(%{state: "removed"})
      |> Repo.update!()

      assert {:ok, _repository} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")
    end

    test "an action built for the old branch is not queued after a change" do
      repository = repository_fixture()

      assert {:ok, _repository} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")

      assert {:error, :repository_branch_changed} =
               Operations.enqueue_agent_action(%{
                 repository_id: repository.id,
                 action_key: "prepare_issue",
                 target_type: "repository",
                 target_id: repository.id,
                 target_label: "Repository",
                 prompt_version: 1,
                 prompt: "Targets main",
                 actor: "andreas",
                 built_for_branch: "main"
               })

      refute Repo.exists?(PtcManager.Operations.AgentAction)
    end

    test "refuses while a collection run is live, even with no member running" do
      repository = repository_fixture()
      umbrella = issue_fixture(repository)

      run =
        Repo.insert!(%PtcManager.Collections.Run{
          repository_id: repository.id,
          issue_id: umbrella.id,
          state: "paused",
          actor: "andreas",
          started_at: DateTime.utc_now()
        })

      assert {:error, :active_work} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")

      run |> Ecto.Changeset.change(state: "completed") |> Repo.update!()

      assert {:ok, _repository} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")
    end

    test "an automation run holding the repository from before a change is not queued" do
      repository = repository_fixture()
      enable_automation!(repository, "nightly_ci_investigation")
      definition = PtcManager.Automations.get_definition(repository, "nightly_ci_investigation")

      trigger =
        definition.triggers
        |> Enum.find(&(&1.trigger_type == "manual"))
        |> Ecto.Changeset.change(enabled: true)
        |> Repo.update!()
        |> Repo.preload(automation_definition: [:repository, :current_version])

      assert {:ok, _repository} =
               Operations.update_repository_branch(repository.id, "develop", "andreas")

      assert {:error, :repository_branch_changed} =
               PtcManager.Automations.run_trigger(trigger, "andreas", occurrence_key: "manual:x")

      refute Repo.exists?(PtcManager.Operations.AgentAction)
    end

    test "saving the same branch changes nothing" do
      repository = repository_fixture()

      assert {:ok, %{default_branch: "main"}} =
               Operations.update_repository_branch(repository.id, "main", "andreas")

      refute Repo.get_by(AuditEvent, action: "repository.default_branch_changed")
    end
  end

  describe "onboarding" do
    setup do
      previous = Application.get_env(:ptc_manager, :test_github_repositories, :all)
      on_exit(fn -> Application.put_env(:ptc_manager, :test_github_repositories, previous) end)

      Application.put_env(:ptc_manager, :test_github_repositories, %{
        {"tyraorg", "api"} =>
          {:ok, %{"nameWithOwner" => "tyraorg/api", "defaultBranchRef" => %{"name" => "develop"}}}
      })
    end

    test "a blank branch takes GitHub's default branch" do
      assert {:ok, repository} =
               Operations.onboard_repository(%{
                 github_owner: "tyraorg",
                 github_name: "api",
                 default_branch: " "
               })

      assert repository.default_branch == "develop"
      assert repository.github_default_branch == "develop"
    end

    test "an explicit branch wins and is validated" do
      assert {:error, :invalid_branch} =
               Operations.onboard_repository(%{
                 github_owner: "tyraorg",
                 github_name: "api",
                 default_branch: "../main"
               })

      assert {:ok, repository} =
               Operations.onboard_repository(%{
                 github_owner: "tyraorg",
                 github_name: "api",
                 default_branch: "main"
               })

      assert repository.default_branch == "main"
      assert repository.github_default_branch == "develop"
    end

    test "looks up GitHub's default branch for the form" do
      assert {:ok, "develop"} = Operations.lookup_github_default_branch(" tyraorg ", "api")

      assert {:error, :repository_not_found} =
               Operations.lookup_github_default_branch("tyraorg", "missing")

      assert {:error, :unsafe_repository_name} =
               Operations.lookup_github_default_branch("tyraorg", "../x")
    end
  end

  defp open_publication!(job) do
    now = DateTime.utc_now()
    sha = String.duplicate("a", 40)

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      state: "published",
      idempotency_key: String.duplicate("7", 64),
      fencing_token: job.fencing_token,
      branch_name: "ptc-manager/issue-job-#{job.id}",
      base_sha: sha,
      head_sha: sha,
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: 4242,
      pr_url: "https://github.com/example/repo/pull/4242",
      remote_head_sha: sha,
      remote_base_sha: sha,
      published_at: now,
      pr_state: "open",
      pr_checked_at: now,
      source: "agent"
    })
    |> Repo.insert!()
  end
end
