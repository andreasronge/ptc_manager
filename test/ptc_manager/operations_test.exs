defmodule PtcManager.OperationsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{Approval, AuditEvent, Issue, Job}
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

      approval = Repo.get!(Approval, job.approval_id)
      assert approval.proposal_id == proposal.id
      assert approval.actor == "andreas"
      assert approval.source_digest == issue.content_digest
      assert approval.proposal_digest == proposal.proposal_digest

      audit = Repo.one!(AuditEvent)
      assert audit.target_id == job.id
      assert audit.details["issue_number"] == issue.number
      assert audit.details["proposal_digest"] == proposal.proposal_digest
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
end
