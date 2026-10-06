defmodule PtcManager.BranchPrefixesTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{AuditEvent, Job, Repository}
  alias PtcManager.Repository.BranchPrefixes

  describe "valid_prefix?/1" do
    test "accepts one to three safe segments, each ending in a slash" do
      for prefix <- ~w(bugfix/ feature/ ptc-manager/ team/bugfix/ a/b/c/ v1.2/ Hot_fix/) do
        assert BranchPrefixes.valid_prefix?(prefix), prefix
      end
    end

    test "refuses anything git could misread or that leaves the job id ambiguous" do
      for prefix <- [
            nil,
            "",
            "/",
            "bugfix",
            "bugfix-",
            "bugfix//",
            "/bugfix/",
            "a/b/c/d/",
            "-bugfix/",
            ".bugfix/",
            "bug..fix/",
            "bugfix./",
            "bugfix.lock/",
            "bug fix/",
            "bug@{fix/",
            "refs/heads/",
            "origin/",
            "HEAD/",
            "Remotes/x/",
            String.duplicate("a", 64) <> "/"
          ] do
        refute BranchPrefixes.valid_prefix?(prefix), inspect(prefix)
      end
    end
  end

  describe "resolve/2" do
    test "maps only configured labels, case-insensitively, and names every conflicting label" do
      repository = %Repository{
        branch_prefixes: %{
          "default" => "feature/",
          "mappings" => [
            %{"label" => "bug", "prefix" => "bugfix/"},
            %{"label" => "Defect", "prefix" => "bugfix/"},
            %{"label" => "urgent", "prefix" => "hotfix/"}
          ]
        }
      }

      assert {:ok, "feature/"} = BranchPrefixes.resolve(repository, [])
      assert {:ok, "feature/"} = BranchPrefixes.resolve(repository, ["release", "docs"])
      assert {:ok, "bugfix/"} = BranchPrefixes.resolve(repository, ["BUG"])
      assert {:ok, "bugfix/"} = BranchPrefixes.resolve(repository, ["bug", "defect"])

      assert {:error, {:conflicting_branch_prefixes, mappings}} =
               BranchPrefixes.resolve(repository, ["bug", "defect", "urgent"])

      assert Enum.map(mappings, & &1["label"]) == ["bug", "Defect", "urgent"]
      assert BranchPrefixes.choices(repository) == ["feature/", "bugfix/", "hotfix/"]
    end

    test "a repository that never configured anything keeps the legacy prefix" do
      assert {:ok, "ptc-manager/"} = BranchPrefixes.resolve(%Repository{}, ["bug"])
      assert BranchPrefixes.choices(%Repository{}) == ["ptc-manager/"]
    end
  end

  test "branch_name/3 builds only from a valid prefix" do
    assert {:ok, "bugfix/issue-12-job-34"} = BranchPrefixes.branch_name("bugfix/", 12, 34)
    assert {:error, :invalid_branch_prefix} = BranchPrefixes.branch_name(nil, 12, 34)
    assert {:error, :invalid_branch_prefix} = BranchPrefixes.branch_name("bugfix", 12, 34)
    assert {:error, :invalid_branch_prefix} = BranchPrefixes.branch_name("bugfix/", nil, 34)
  end

  test "colliding_branch/2 checks every ancestor of the prefix" do
    repository = %Repository{github_branch_names: %{"names" => ["main", "team", "bugfix/x"]}}

    assert BranchPrefixes.colliding_branch(repository, "team/bugfix/") == "team"
    assert BranchPrefixes.colliding_branch(repository, "bugfix/") == nil

    repository = %Repository{github_branch_names: %{"names" => ["team/bugfix"]}}
    assert BranchPrefixes.colliding_branch(repository, "team/bugfix/") == "team/bugfix"
  end

  describe "maintaining prefixes" do
    test "every change is validated, audited, and stored as a whole" do
      repository = repository_fixture()
      assert BranchPrefixes.default(repository) == "ptc-manager/"

      assert {:error, :invalid_branch_prefix} =
               Operations.set_default_branch_prefix(repository.id, "feature", "andreas")

      assert {:ok, updated} =
               Operations.set_default_branch_prefix(repository.id, " feature/ ", "andreas")

      assert BranchPrefixes.default(updated) == "feature/"

      assert {:error, :reserved_label_name} =
               Operations.add_branch_prefix_mapping(repository.id, "ptc:ready", "x/", "andreas")

      assert {:error, :invalid_label_name} =
               Operations.add_branch_prefix_mapping(repository.id, "", "x/", "andreas")

      assert {:ok, mapped} =
               Operations.add_branch_prefix_mapping(repository.id, "bug", "bugfix/", "andreas")

      assert BranchPrefixes.list(mapped) == [%{"label" => "bug", "prefix" => "bugfix/"}]

      assert {:error, :label_already_mapped} =
               Operations.add_branch_prefix_mapping(repository.id, "BUG", "hotfix/", "andreas")

      assert {:ok, removed} =
               Operations.remove_branch_prefix_mapping(repository.id, "bug", "andreas")

      assert BranchPrefixes.list(removed) == []
      assert BranchPrefixes.default(removed) == "feature/"

      audits =
        Repo.all(
          from a in AuditEvent,
            where: a.action == "repository.branch_prefixes_updated",
            order_by: a.id
        )

      assert [first, second, third] = audits
      assert first.details["default_set"] == "feature/"
      assert second.details["mappings"] == [%{"label" => "bug", "prefix" => "bugfix/"}]
      assert third.details["removed"] == "bug"
    end

    test "a prefix a cached branch would block is refused, but removal and sync still work" do
      repository = repository_fixture()

      {:ok, _mapped} =
        Operations.add_branch_prefix_mapping(repository.id, "bug", "bugfix/", "andreas")

      Repo.get!(Repository, repository.id)
      |> Repository.changeset(%{github_branch_names: %{"names" => ["main", "hotfix", "bugfix"]}})
      |> Repo.update!()

      assert {:error, :branch_prefix_collides} =
               Operations.add_branch_prefix_mapping(repository.id, "urgent", "hotfix/", "andreas")

      assert {:error, :branch_prefix_collides} =
               Operations.set_default_branch_prefix(repository.id, "hotfix/", "andreas")

      assert {:ok, removed} =
               Operations.remove_branch_prefix_mapping(repository.id, "bug", "andreas")

      assert BranchPrefixes.list(removed) == []
    end

    test "the repository changeset refuses a malformed stored shape" do
      repository = repository_fixture()

      for value <- [
            %{"default" => "feature"},
            %{"default" => "feature", "mappings" => []},
            %{"default" => "feature/", "mappings" => [%{"label" => "ptc:x", "prefix" => "x/"}]},
            %{
              "default" => "feature/",
              "mappings" => [
                %{"label" => "bug", "prefix" => "a/"},
                %{"label" => "BUG", "prefix" => "b/"}
              ]
            }
          ] do
        refute Repository.changeset(repository, %{branch_prefixes: value}).valid?,
               inspect(value)
      end
    end
  end

  describe "approval" do
    test "an issue's own mapped label decides the prefix and the job freezes it" do
      repository = bug_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["Bug"]}})

      assert {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      assert job.branch_prefix == "bugfix/"

      audit = Repo.get_by!(AuditEvent, target_id: job.id, target_type: "job")
      assert audit.details["branch_prefix"] == "bugfix/"
      refute audit.details["branch_prefix_override"]
      assert audit.details["branch_prefix_conflict"] == nil
    end

    test "an unmapped issue gets the default prefix" do
      repository = bug_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["docs"]}})

      assert {:ok, %{branch_prefix: "feature/"}} =
               Operations.approve_issue_directly(issue.id, "andreas")
    end

    test "an umbrella's label does not rename its members' branches" do
      repository = bug_repository()
      umbrella = issue_fixture(repository, %{number: 501, github_labels: %{"names" => ["bug"]}})
      member = issue_fixture(repository, %{parent_issue_number: umbrella.number})

      assert {:ok, %{branch_prefix: "feature/"}} =
               Operations.approve_issue_directly(member.id, "andreas")
    end

    test "the maintainer may pick any configured prefix, and the pick is audited" do
      repository = bug_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["bug"]}})

      assert {:ok, job} =
               Operations.approve_issue_directly(issue.id, "andreas", nil, nil,
                 branch_prefix: "feature/"
               )

      assert job.branch_prefix == "feature/"
      audit = Repo.get_by!(AuditEvent, target_id: job.id, target_type: "job")
      assert audit.details["branch_prefix_override"]
    end

    test "a prefix that is not configured is refused" do
      repository = bug_repository()
      issue = issue_fixture(repository)

      assert {:error, :invalid_branch_prefix} =
               Operations.approve_issue_directly(issue.id, "andreas", nil, nil,
                 branch_prefix: "release/"
               )

      refute Repo.exists?(from j in Job, where: j.issue_id == ^issue.id)
    end

    test "a conflict needs the maintainer's pick" do
      repository = conflicting_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["bug", "urgent"]}})

      for choice <- [nil, ""] do
        assert {:error, :conflicting_branch_prefixes} =
                 Operations.approve_issue_directly(issue.id, "andreas", nil, nil,
                   branch_prefix: choice
                 )
      end

      assert {:ok, job} =
               Operations.approve_issue_directly(issue.id, "andreas", nil, nil,
                 branch_prefix: "hotfix/"
               )

      assert job.branch_prefix == "hotfix/"
      audit = Repo.get_by!(AuditEvent, target_id: job.id, target_type: "job")
      assert audit.details["branch_prefix_override"]
      assert audit.details["branch_prefix_conflict"] == ["bug", "urgent"]
    end

    test "an unattended approval settles a conflict with the default prefix" do
      repository = conflicting_repository()

      {:ok, _repository} =
        repository
        |> Repository.changeset(%{auto_fix_issues: true})
        |> Repo.update()

      issue =
        issue_fixture(repository, %{
          github_labels: %{"names" => ["bug", "urgent"]},
          workflow_label: "ptc:ready"
        })

      assert {:ok, job} = Operations.auto_approve_issue(issue.id)
      assert job.branch_prefix == "feature/"

      audit = Repo.get_by!(AuditEvent, target_id: job.id, target_type: "job")
      assert audit.details["branch_prefix_conflict"] == ["bug", "urgent"]
      refute audit.details["branch_prefix_override"]
    end

    test "configuration and label changes after approval leave the job's prefix alone" do
      repository = bug_repository()
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["bug"]}})
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")

      issue |> Ecto.Changeset.change(github_labels: %{"names" => []}) |> Repo.update!()

      {:ok, _repository} =
        Operations.remove_branch_prefix_mapping(repository.id, "bug", "andreas")

      {:ok, _repository} =
        Operations.set_default_branch_prefix(repository.id, "other/", "andreas")

      assert Repo.get!(Job, job.id).branch_prefix == "bugfix/"
    end
  end

  test "rows written without the new columns read back with the legacy prefix" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    {:ok, approved} = Operations.approve_issue_directly(issue.id, "andreas")
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all("repositories", [
        %{
          github_owner: "legacy",
          github_name: "repo",
          default_branch: "main",
          inserted_at: now,
          updated_at: now
        }
      ])

    {1, _} =
      Repo.insert_all("jobs", [
        %{
          repository_id: repository.id,
          issue_id: issue.id,
          approval_id: approved.approval_id,
          kind: "implementation",
          state: "done",
          fencing_token: 0,
          base_branch: "main",
          inserted_at: now,
          updated_at: now
        }
      ])

    legacy = Repo.get_by!(Repository, github_owner: "legacy")
    assert BranchPrefixes.default(legacy) == "ptc-manager/"
    assert BranchPrefixes.list(legacy) == []

    assert Repo.one!(
             from j in Job,
               where: j.id != ^approved.id and j.issue_id == ^issue.id,
               select: j.branch_prefix
           ) == "ptc-manager/"
  end

  test "a job built without a prefix keeps the legacy one" do
    assert %Job{}.branch_prefix == "ptc-manager/"
    refute Job.changeset(%Job{}, %{branch_prefix: "nope"}).valid?
  end

  defp bug_repository do
    repository = repository_fixture()
    {:ok, _} = Operations.set_default_branch_prefix(repository.id, "feature/", "andreas")

    {:ok, repository} =
      Operations.add_branch_prefix_mapping(repository.id, "bug", "bugfix/", "andreas")

    repository
  end

  defp conflicting_repository do
    repository = bug_repository()

    {:ok, repository} =
      Operations.add_branch_prefix_mapping(repository.id, "urgent", "hotfix/", "andreas")

    repository
  end
end
