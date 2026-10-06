defmodule PtcManager.IntegrationBranchesTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{Approval, AuditEvent, Job, PrPublication, Repository}
  alias PtcManager.Repository.IntegrationBranches

  setup do
    previous = Application.get_env(:ptc_manager, :test_github_branches)
    Application.put_env(:ptc_manager, :test_github_branches, ["main", "feature/ska", "feature/x"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ptc_manager, :test_github_branches, previous),
        else: Application.delete_env(:ptc_manager, :test_github_branches)
    end)
  end

  describe "IntegrationBranches" do
    test "resolves active mappings case-insensitively and refuses two different branches" do
      repository =
        mapped(%{
          "mappings" => [
            %{"label" => "ska", "branch" => "feature/ska", "active" => true},
            %{"label" => "Also-SKA", "branch" => "feature/ska", "active" => true},
            %{"label" => "x", "branch" => "feature/x", "active" => true},
            %{"label" => "old", "branch" => "feature/old", "active" => false}
          ]
        })

      assert {:ok, nil} = IntegrationBranches.resolve(repository, ["bug"])

      assert {:ok, %{"branch" => "feature/ska"}} =
               IntegrationBranches.resolve(repository, ["SKA"])

      # Two labels that agree on the branch are one route.
      assert {:ok, %{"branch" => "feature/ska"}} =
               IntegrationBranches.resolve(repository, ["ska", "also-ska"])

      # An inactive mapping routes nothing.
      assert {:ok, nil} = IntegrationBranches.resolve(repository, ["old"])

      assert {:error, {:conflicting_integration_branches, [_, _]}} =
               IntegrationBranches.resolve(repository, ["ska", "x"])
    end

    test "suggests only labels with a matching feature/ branch and no mapping" do
      repository = %Repository{
        github_label_names: %{"names" => ["ska", "cleanup", "ptc:ready", "mapped", "bug"]},
        github_branch_names: %{
          "names" => [
            "main",
            "feature/ska",
            "feature/cleanup",
            "feature/mapped",
            "feature/ptc:ready"
          ]
        },
        integration_branches: %{
          "mappings" => [%{"label" => "mapped", "branch" => "feature/mapped", "active" => true}]
        }
      }

      assert IntegrationBranches.suggestions(repository) == [
               %{"label" => "ska", "branch" => "feature/ska"},
               %{"label" => "cleanup", "branch" => "feature/cleanup"}
             ]
    end

    test "add refuses reserved labels, unsafe branches, and a second mapping for a label" do
      repository = %Repository{integration_branches: %{"mappings" => []}}

      assert {:error, :reserved_label_name} =
               IntegrationBranches.add(repository, "ptc:ready", "feature/x")

      assert {:error, :invalid_branch} = IntegrationBranches.add(repository, "ska", "a..b")
      assert {:ok, stored} = IntegrationBranches.add(repository, " ska ", " feature/ska ")

      assert stored == %{
               "mappings" => [%{"label" => "ska", "branch" => "feature/ska", "active" => true}]
             }

      assert {:error, :label_already_mapped} =
               IntegrationBranches.add(
                 %{repository | integration_branches: stored},
                 "SKA",
                 "feature/x"
               )
    end
  end

  describe "maintaining mappings" do
    test "a mapping is saved only for a branch GitHub reports, and every change is audited" do
      repository = repository_fixture()

      assert {:error, :branch_not_found} =
               Operations.add_integration_branch(
                 repository.id,
                 "ska",
                 "feature/missing",
                 "andreas"
               )

      assert {:ok, updated} =
               Operations.add_integration_branch(repository.id, "ska", "feature/ska", "andreas")

      assert [%{"label" => "ska", "active" => true}] = IntegrationBranches.list(updated)

      assert {:ok, off} =
               Operations.set_integration_branch_active(repository.id, "ska", false, "andreas")

      assert [%{"active" => false}] = IntegrationBranches.list(off)

      assert {:ok, removed} =
               Operations.remove_integration_branch(repository.id, "ska", "andreas")

      assert IntegrationBranches.list(removed) == []

      assert Repo.aggregate(
               from(a in AuditEvent,
                 where: a.action == "repository.integration_branches_updated"
               ),
               :count
             ) == 3
    end
  end

  describe "approval" do
    test "a mapped label stores the integration branch on the approval and the job" do
      repository = ska_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      assert {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      assert job.base_branch == "feature/ska"

      approval = Repo.get!(Approval, job.approval_id)
      assert approval.base_branch == "feature/ska"
      refute approval.base_override

      audit = Repo.get_by!(AuditEvent, target_id: job.id, target_type: "job")
      assert audit.details["base_branch"] == "feature/ska"
    end

    test "the maintainer can send one issue to the default branch instead" do
      repository = ska_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      assert {:ok, job} =
               Operations.approve_issue_directly(issue.id, "andreas", nil, nil, base: :default)

      assert job.base_branch == "main"
      assert Repo.get!(Approval, job.approval_id).base_override
    end

    test "an issue without a mapped label, or with a switched-off mapping, targets the default branch" do
      repository = ska_repository()
      plain = issue_fixture(repository, %{github_labels: %{"names" => ["bug"]}})

      assert {:ok, %{base_branch: "main"}} =
               Operations.approve_issue_directly(plain.id, "andreas")

      {:ok, _repository} =
        Operations.set_integration_branch_active(repository.id, "ska", false, "andreas")

      labelled = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      assert {:ok, %{base_branch: "main"}} =
               Operations.approve_issue_directly(labelled.id, "andreas")
    end

    test "a member follows its umbrella's label" do
      repository = ska_repository()
      umbrella = issue_fixture(repository, %{number: 123, github_labels: %{"names" => ["ska"]}})
      member = issue_fixture(repository, %{parent_issue_number: umbrella.number})

      assert {:ok, %{base_branch: "feature/ska"}} =
               Operations.approve_issue_directly(member.id, "andreas")
    end

    test "labels that map to different branches block approval" do
      repository = ska_repository()

      {:ok, _repository} =
        Operations.add_integration_branch(repository.id, "x", "feature/x", "andreas")

      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska", "x"]}})

      assert {:error, :conflicting_integration_branches} =
               Operations.approve_issue_directly(issue.id, "andreas")

      refute Repo.exists?(from j in Job, where: j.issue_id == ^issue.id)
    end

    test "an issue already merged into its integration branch is not implemented again" do
      repository = ska_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      job = job |> Job.changeset(%{state: "done"}) |> Repo.update!()
      Repo.update_all(PtcManager.Automations.Invocation, set: [state: "succeeded"])
      merged_publication!(job)

      assert {:error, :already_integrated} =
               Operations.approve_issue_directly(issue.id, "andreas")

      # The default branch is a different target, and stays the maintainer's call.
      assert {:ok, %{base_branch: "main"}} =
               Operations.approve_issue_directly(issue.id, "andreas", nil, nil, base: :default)
    end

    test "a label change after approval does not retarget the job" do
      repository = ska_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")

      issue |> Ecto.Changeset.change(github_labels: %{"names" => []}) |> Repo.update!()
      {:ok, _repository} = Operations.remove_integration_branch(repository.id, "ska", "andreas")

      assert Repo.get!(Job, job.id).base_branch == "feature/ska"
    end
  end

  test "synchronization records the repository's branch names" do
    repository = repository_fixture()

    assert {:ok, _summary} =
             PtcManager.GitHub.Sync.sync_repository(repository,
               client: PtcManager.TestGitHubClient
             )

    assert Repo.get!(Repository, repository.id).github_branch_names == %{
             "names" => ["main", "feature/ska", "feature/x"]
           }
  end

  defp ska_repository do
    repository = repository_fixture()

    {:ok, repository} =
      Operations.add_integration_branch(repository.id, "ska", "feature/ska", "andreas")

    repository
  end

  defp mapped(branches), do: %Repository{integration_branches: branches}

  defp merged_publication!(job) do
    now = DateTime.utc_now()
    sha = String.duplicate("a", 40)

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      repository_id: job.repository_id,
      base_branch: job.base_branch,
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
      pr_state: "merged",
      pr_checked_at: now,
      source: "agent"
    })
    |> Repo.insert!()
  end
end
