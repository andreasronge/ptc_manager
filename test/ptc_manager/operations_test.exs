defmodule PtcManager.OperationsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{Approval, AuditEvent, Issue, IssueDependency, Job}
  alias PtcManager.Repo

  describe "approve_issue/2" do
    test "creates an immutable approval, queued job, and audit event in one transaction" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      proposal = proposal_fixture(issue)

      assert {:ok, job} = Operations.approve_issue(issue.id, "andreas")
      assert job.issue_id == issue.id
      assert job.repository_id == repository.id
      assert job.state == "queued"
      assert job.fencing_token == 0
      assert job.required_review_count == 2

      approval = Repo.get!(Approval, job.approval_id)
      assert approval.proposal_id == proposal.id
      assert approval.actor == "andreas"
      assert approval.source_digest == issue.content_digest
      assert approval.proposal_digest == proposal.proposal_digest

      audit = Repo.one!(AuditEvent)
      assert audit.target_id == job.id
      assert audit.details["issue_number"] == issue.number
      assert audit.details["proposal_digest"] == proposal.proposal_digest
      assert audit.details["required_review_count"] == 2
    end

    test "freezes a per-task review count between zero and three" do
      repository = repository_fixture(%{required_pre_pr_reviews: 2})
      easy = issue_fixture(repository, %{number: 501})
      tricky = issue_fixture(repository, %{number: 502})
      proposal_fixture(easy)
      proposal_fixture(tricky)

      assert {:ok, easy_job} = Operations.approve_issue(easy.id, "andreas", 0)
      assert easy_job.required_review_count == 0

      assert {:ok, tricky_job} = Operations.approve_issue(tricky.id, "andreas", 3)
      assert tricky_job.required_review_count == 3

      assert {:error, :invalid_review_count} =
               Operations.approve_issue(tricky.id, "andreas", 4)
    end

    test "fails closed when the latest proposal no longer matches the issue" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      proposal_fixture(issue)

      issue
      |> Issue.changeset(%{content_digest: digest("changed")})
      |> Repo.update!()

      assert {:error, :stale_proposal} = Operations.approve_issue(issue.id, "andreas")
      assert Repo.aggregate(Approval, :count) == 0
      assert Repo.aggregate(Job, :count) == 0
      assert Repo.aggregate(AuditEvent, :count) == 0
    end

    test "database constraint prevents a second active job" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      proposal_fixture(issue)

      assert {:ok, _job} = Operations.approve_issue(issue.id, "andreas")
      assert {:error, :already_active} = Operations.approve_issue(issue.id, "andreas")

      assert Repo.aggregate(Approval, :count) == 1
      assert Repo.aggregate(Job, :count) == 1
      assert Repo.aggregate(AuditEvent, :count) == 1
    end

    test "does not approve a closed issue" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{state: "closed"})
      proposal_fixture(issue)

      assert {:error, :issue_closed} = Operations.approve_issue(issue.id, "andreas")
      assert Repo.aggregate(Job, :count) == 0
    end

    test "does not approve an issue assigned on GitHub" do
      repository = repository_fixture()

      issue =
        issue_fixture(repository, %{
          github_assignees: %{"logins" => ["outside-agent"]}
        })

      proposal_fixture(issue)

      assert {:error, :issue_claimed} = Operations.approve_issue(issue.id, "andreas")
      assert Repo.aggregate(Job, :count) == 0
    end

    test "does not approve before GitHub assignment projection completes" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{github_assignment_projected: false})
      proposal_fixture(issue)

      assert {:error, :issue_claim_unknown} = Operations.approve_issue(issue.id, "andreas")
      assert Repo.aggregate(Job, :count) == 0
    end

    test "does not approve an analysis that is not ready" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      proposal_fixture(issue, %{readiness: "needs_information"})

      assert {:error, :proposal_not_ready} = Operations.approve_issue(issue.id, "andreas")
      assert Repo.aggregate(Job, :count) == 0
    end

    test "does not treat a blocked or conflicting GitHub label as dispatch authority" do
      repository = repository_fixture()
      blocked = issue_fixture(repository, %{workflow_label: "ptc:blocked"})
      proposal_fixture(blocked)

      assert {:error, :issue_workflow_not_ready} =
               Operations.approve_issue(blocked.id, "andreas")

      conflicting = issue_fixture(repository, %{workflow_label_conflict: true})
      proposal_fixture(conflicting)

      assert {:error, :issue_workflow_not_ready} =
               Operations.approve_issue(conflicting.id, "andreas")
    end

    test "does not approve an issue while a projected blocker remains open" do
      repository = repository_fixture()
      blocker = issue_fixture(repository, %{number: 81})
      dependent = issue_fixture(repository, %{number: 82, workflow_label: "ptc:ready"})
      proposal_fixture(dependent)

      dependency =
        issue_dependency_fixture(dependent, %{
          blocking_issue: blocker,
          blocking_repository: repository
        })

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(dependent.id, "andreas")

      blocker
      |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
      |> Repo.update!()

      dependency
      |> IssueDependency.changeset(%{
        blocking_state: "closed",
        blocking_state_reason: "completed"
      })
      |> Repo.update!()

      assert {:ok, job} = Operations.approve_issue(dependent.id, "andreas")
      assert job.state == "queued"
    end

    test "generic issue creation defaults to unprojected and cannot be approved" do
      repository = repository_fixture()
      number = System.unique_integer([:positive])
      body = "Blocked by #999"
      body_digest = digest(body)

      assert {:ok, issue} =
               Operations.create_issue(%{
                 repository_id: repository.id,
                 number: number,
                 title: "Issue #{number}",
                 html_url:
                   "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{number}",
                 body: body,
                 state: "open",
                 body_digest: body_digest,
                 content_digest: digest("Issue #{number}:#{body_digest}"),
                 github_updated_at: now()
               })

      proposal_fixture(issue)

      refute issue.dependencies_projected
      refute issue.github_assignment_projected

      assert {:error, :issue_claim_unknown} =
               Operations.approve_issue(issue.id, "andreas")
    end

    test "does not approve before dependency projection completes" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{dependencies_projected: false})
      proposal_fixture(issue)

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(issue.id, "andreas")
    end

    test "repository-qualified dependencies do not confuse equal issue numbers" do
      repository = repository_fixture(%{github_owner: "owner", github_name: "application"})
      other = repository_fixture(%{github_owner: "owner", github_name: "platform"})

      _completed_decoy =
        issue_fixture(repository, %{
          number: 81,
          state: "closed",
          github_state_reason: "completed"
        })

      blocker = issue_fixture(other, %{number: 81})
      dependent = issue_fixture(repository, %{number: 82, workflow_label: "ptc:ready"})
      proposal_fixture(dependent)
      dependency = dependency_fixture(dependent, blocker, other)

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(dependent.id, "andreas")

      blocker
      |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
      |> Repo.update!()

      dependency
      |> IssueDependency.changeset(%{
        blocking_state: "closed",
        blocking_state_reason: "completed"
      })
      |> Repo.update!()

      assert {:ok, job} = Operations.approve_issue(dependent.id, "andreas")
      assert job.state == "queued"
    end

    test "a dependency closed as not planned requires a maintainer decision" do
      repository = repository_fixture(%{github_owner: "owner", github_name: "application"})
      dependent = issue_fixture(repository, %{workflow_label: "ptc:ready"})
      proposal_fixture(dependent)

      issue_dependency_fixture(dependent, %{
        issue_id: dependent.id,
        blocking_repository_full_name: "outside/platform",
        blocking_issue_number: 9,
        blocking_title: "Cancelled platform work",
        blocking_html_url: "https://github.com/outside/platform/issues/9",
        blocking_state: "closed",
        blocking_state_reason: "not_planned",
        lookup_state: "resolved"
      })

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(dependent.id, "andreas")
    end

    test "a closed dependency without an explicit completed reason fails closed" do
      repository = repository_fixture()
      dependent = issue_fixture(repository, %{workflow_label: "ptc:ready"})
      proposal_fixture(dependent)

      issue_dependency_fixture(dependent, %{
        blocking_repository: repository,
        blocking_issue_number: 9,
        blocking_title: "Closure reason unavailable",
        blocking_html_url: "https://github.com/owner/repo/issues/9",
        blocking_state: "closed",
        blocking_state_reason: nil,
        lookup_state: "resolved"
      })

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(dependent.id, "andreas")
    end

    test "an unknown edge close reason cannot inherit completion from its linked issue" do
      repository = repository_fixture()

      blocker =
        issue_fixture(repository, %{
          number: 19,
          state: "closed",
          github_state_reason: "completed"
        })

      dependent = issue_fixture(repository, %{workflow_label: "ptc:ready"})
      proposal_fixture(dependent)

      issue_dependency_fixture(dependent, %{
        blocking_issue: blocker,
        blocking_repository: repository,
        blocking_state: "closed",
        blocking_state_reason: nil
      })

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(dependent.id, "andreas")
    end

    test "a blocker hidden from the GitHub reader fails approval closed" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{dependency_unknown_count: 1})
      proposal_fixture(issue)

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue(issue.id, "andreas")
    end
  end

  describe "create_agent_run/1" do
    test "requires an end time for a terminal run" do
      worker = worker_fixture()
      now = now()

      assert {:error, changeset} =
               Operations.create_agent_run(%{
                 worker_id: worker.id,
                 role: "reviewer",
                 state: "done",
                 started_at: DateTime.add(now, -60, :second),
                 last_heartbeat_at: now
               })

      assert "is required when the run has ended" in errors_on(changeset).ended_at
    end
  end

  defp dependency_fixture(issue, blocker, repository) do
    issue_dependency_fixture(issue, %{
      blocking_issue: blocker,
      blocking_repository: repository
    })
  end
end
