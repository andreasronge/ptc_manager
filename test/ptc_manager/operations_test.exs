defmodule PtcManager.OperationsTest do
  use PtcManager.DataCase, async: false

  defmodule ClosingHerdrClient do
    def list_agents, do: {:ok, []}

    def close_pane(pane_id) do
      send(Application.fetch_env!(:ptc_manager, :operations_cancel_test_pid), {:closed, pane_id})
      :ok
    end
  end

  defmodule FailingHerdrClient do
    def list_agents, do: {:ok, []}
    def close_pane(_pane_id), do: {:error, :herdr_timeout}
  end

  defmodule RecordingLabelWriter do
    @behaviour PtcManager.GitHub.IssueLabelWriter

    @impl true
    def write(repository, number, operation, label) do
      send(
        Application.fetch_env!(:ptc_manager, :operations_label_test_pid),
        {:label_written, repository, number, operation, label}
      )

      Application.get_env(:ptc_manager, :operations_label_result, :ok)
    end
  end

  defmodule LabelGitHubClient do
    @behaviour PtcManager.GitHub

    @impl true
    def list_open_issues(_repository), do: {:ok, []}

    @impl true
    def get_issue(_repository, _number),
      do: Application.fetch_env!(:ptc_manager, :operations_label_remote_issue)
  end

  alias PtcManager.Operations
  alias PtcManager.Operations.AgentHealth
  alias PtcManager.GitHub.IssueLabels
  alias PtcManager.MaintainerActions
  alias PtcManager.Operations.DeliveryLane
  alias PtcManager.Operations.PlanningGroup
  alias PtcManager.Operations.StopReport
  alias PtcManager.Operations.Proposal

  alias PtcManager.Operations.{
    AgentAction,
    AgentRun,
    Approval,
    AuditEvent,
    Issue,
    IssueDependency,
    Job,
    WorktreeAllocation
  }

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
      assert job.required_review_count == 1

      approval = Repo.get!(Approval, job.approval_id)
      assert approval.proposal_id == proposal.id
      assert approval.actor == "andreas"
      assert approval.source_digest == issue.content_digest
      assert approval.proposal_digest == proposal.proposal_digest

      audit = Repo.one!(AuditEvent)
      assert audit.target_id == job.id
      assert audit.details["issue_number"] == issue.number
      assert audit.details["proposal_digest"] == proposal.proposal_digest
      assert audit.details["required_review_count"] == 1
    end

    test "freezes a per-task review count between zero and five" do
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
               Operations.approve_issue(tricky.id, "andreas", 6)
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

  describe "queued work and stale idle attempts" do
    test "cancels only work that is still queued" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      proposal_fixture(issue)
      {:ok, job} = Operations.approve_issue(issue.id, "andreas")
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      action =
        %AgentAction{}
        |> AgentAction.changeset(%{
          repository_id: repository.id,
          action_key: "review_issue",
          target_type: "issue",
          target_id: issue.id,
          target_label: "example/repo##{issue.number}",
          prompt_version: 1,
          prompt: "Review the issue",
          actor: "andreas",
          state: "queued",
          requested_at: now
        })
        |> Repo.insert!()

      assert {:ok, cancelled_job} = Operations.cancel_queued_job(job.id, "andreas")
      assert cancelled_job.state == "cancelled"
      assert cancelled_job.ended_at
      assert {:error, :work_no_longer_queued} = Operations.cancel_queued_job(job.id, "andreas")

      assert {:ok, cancelled_action} =
               Operations.cancel_queued_agent_action(action.id, "andreas")

      assert cancelled_action.state == "cancelled"
      assert cancelled_action.ended_at
      assert Repo.aggregate(AuditEvent, :count, :id) == 3
    end

    test "an expired idle attempt releases capacity and preserves its worktree" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      proposal_fixture(issue)
      {:ok, job} = Operations.approve_issue(issue.id, "andreas")
      worker = worker_fixture(%{worker_key: "herdr:idle-expiry"})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      job =
        job
        |> Job.changeset(%{
          state: "idle",
          fencing_token: 1,
          lease_owner: worker.worker_key,
          lease_expires_at: DateTime.add(now, -1, :second),
          started_at: DateTime.add(now, -600, :second),
          branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
        })
        |> Repo.update!()

      allocation =
        %WorktreeAllocation{}
        |> WorktreeAllocation.changeset(%{
          worker_id: worker.id,
          job_id: job.id,
          state: "active",
          path: "/tmp/preserved-idle-worktree",
          last_used_at: now
        })
        |> Repo.insert!()

      {:ok, run} =
        Operations.create_agent_run(%{
          worker_id: worker.id,
          job_id: job.id,
          role: "implementer",
          state: "idle",
          started_at: job.started_at,
          last_heartbeat_at: now,
          fencing_token: 1
        })

      assert Operations.expire_job_leases(now) == 1
      assert Repo.get!(Job, job.id).state == "lost"
      assert Repo.get!(AgentRun, run.id).state == "lost"

      preserved = Repo.get!(WorktreeAllocation, allocation.id)
      assert preserved.state == "attention"
      assert preserved.last_error =~ "partial worktree was preserved"
    end
  end

  describe "cancel_running_job/2" do
    setup do
      previous = Application.get_env(:ptc_manager, :herdr_client)
      Application.put_env(:ptc_manager, :operations_cancel_test_pid, self())
      Application.put_env(:ptc_manager, :herdr_client, ClosingHerdrClient)

      on_exit(fn ->
        Application.put_env(:ptc_manager, :herdr_client, previous)
        Application.delete_env(:ptc_manager, :operations_cancel_test_pid)
      end)

      :ok
    end

    test "ends the run, keeps the worktree for attention, and closes the pane" do
      %{job: job, run: run, allocation: allocation} = running_job_fixture("working")

      assert {:ok, cancelled} = Operations.cancel_running_job(job.id, "andreas")
      assert cancelled.state == "cancelled"
      assert cancelled.ended_at
      assert is_nil(cancelled.lease_expires_at)
      assert cancelled.last_error =~ "Cancelled by andreas"

      ended_run = Repo.get!(AgentRun, run.id)
      assert ended_run.state == "lost"
      assert ended_run.status_text == "Cancelled by maintainer"
      assert ended_run.ended_at

      preserved = Repo.get!(WorktreeAllocation, allocation.id)
      assert preserved.state == "attention"
      assert preserved.last_error =~ "partial worktree was preserved"

      audit = Repo.get_by!(AuditEvent, action: "job.cancelled")
      assert audit.details["agent_run_id"] == run.id
      assert audit.details["herdr_pane"] == "w7:p1"
      assert audit.details["worktree_preserved"] == true

      assert_receive {:closed, "w7:p1"}
    end

    test "reports a pane that refused to close while keeping the job cancelled" do
      Application.put_env(:ptc_manager, :herdr_client, FailingHerdrClient)
      %{job: job} = running_job_fixture("blocked")

      assert {:ok, cancelled, {:pane_close_failed, :herdr_timeout}} =
               Operations.cancel_running_job(job.id, "andreas")

      assert cancelled.state == "cancelled"
    end

    test "refuses the deterministic phases PtcManager owns itself" do
      %{job: job} = running_job_fixture("verifying_result")

      assert {:error, :job_not_cancellable} = Operations.cancel_running_job(job.id, "andreas")
      assert Repo.get!(Job, job.id).state == "verifying_result"
    end

    test "the dispatcher does not pick a cancelled job up again" do
      %{job: job} = running_job_fixture("working")

      assert {:ok, _cancelled} = Operations.cancel_running_job(job.id, "andreas")
      assert is_nil(Operations.next_queued_job())
    end
  end

  describe "abandon_stuck_job/2" do
    test "ends a job PtcManager can never finish checking" do
      %{job: job, run: run, allocation: allocation} = running_job_fixture("working")

      # The agent finished and committed nothing, so verification fails forever.
      job =
        job
        |> Job.changeset(%{state: "awaiting_reconciliation", last_error: ":no_commits"})
        |> Repo.update!()

      Repo.get!(AgentRun, run.id)
      |> AgentRun.changeset(%{state: "done", ended_at: DateTime.utc_now()})
      |> Repo.update!()

      assert {:ok, abandoned} = Operations.abandon_stuck_job(job.id, "andreas")
      assert abandoned.state == "cancelled"
      assert abandoned.ended_at
      assert abandoned.last_error =~ "Abandoned by andreas"
      assert abandoned.last_error =~ ":no_commits"

      preserved = Repo.get!(WorktreeAllocation, allocation.id)
      assert preserved.state == "attention"

      audit = Repo.get_by!(AuditEvent, action: "job.abandoned")
      assert audit.details["abandoned_state"] == "awaiting_reconciliation"
      assert audit.details["last_error"] == ":no_commits"

      # It leaves the board, and cannot be abandoned twice.
      assert {:error, :job_not_abandonable} = Operations.abandon_stuck_job(job.id, "andreas")
    end

    test "refuses a phase that is still moving or that already published" do
      %{job: job} = running_job_fixture("working")

      # `reconciling` stays out: it can mean an agent whose remote state is
      # unknown, so freeing the slot could run beside an agent still writing.
      for state <-
            ~w(queued starting working idle blocked reconciling ready_for_pr publishing_pr pr_open) do
        Job |> Repo.get!(job.id) |> Job.changeset(%{state: state}) |> Repo.update!()

        assert {:error, :job_not_abandonable} = Operations.abandon_stuck_job(job.id, "andreas")
        assert Repo.get!(Job, job.id).state == state
      end
    end

    test "refuses a blocked publication that already has a pull request" do
      %{job: job} = running_job_fixture("working")
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      head_sha = String.duplicate("b", 40)

      job =
        job
        |> Job.changeset(%{
          state: "publish_blocked",
          last_error: "GitHub reports a different pull-request head commit.",
          result_base_sha: String.duplicate("a", 40),
          result_head_sha: head_sha,
          result_diff_digest: String.duplicate("c", 64),
          result_commit_count: 1,
          result_verified_at: now
        })
        |> Repo.update!()

      # No publication yet: nothing is orphaned by ending it.
      assert {:ok, _job} = Operations.abandon_stuck_job(job.id, "andreas")

      %{job: second} = running_job_fixture("working")

      second =
        second
        |> Job.changeset(%{
          state: "publish_blocked",
          result_base_sha: String.duplicate("a", 40),
          result_head_sha: head_sha,
          result_diff_digest: String.duplicate("c", 64),
          result_commit_count: 1,
          result_verified_at: now
        })
        |> Repo.update!()

      %PtcManager.Operations.PrPublication{}
      |> PtcManager.Operations.PrPublication.changeset(%{
        job_id: second.id,
        state: "published",
        idempotency_key: String.duplicate("7", 64),
        fencing_token: second.fencing_token,
        branch_name: "ptc-manager/issue-job-#{second.id}",
        base_sha: String.duplicate("a", 40),
        head_sha: head_sha,
        diff_digest: String.duplicate("c", 64),
        attempt_count: 1,
        pr_number: 4242,
        pr_url: "https://github.com/example/repo/pull/4242",
        remote_head_sha: head_sha,
        remote_base_sha: String.duplicate("a", 40),
        published_at: now,
        pr_state: "open",
        pr_checked_at: now,
        source: "agent"
      })
      |> Repo.insert!()

      # An open pull request would be orphaned, and the issue freed for a
      # second approval while that PR still stands.
      assert {:error, :pull_request_open} = Operations.abandon_stuck_job(second.id, "andreas")
      assert Repo.get!(Job, second.id).state == "publish_blocked"
    end

    test "abandons a job whose stored error already fills the column" do
      %{job: job} = running_job_fixture("working")

      job =
        job
        |> Job.changeset(%{
          state: "awaiting_reconciliation",
          last_error: String.duplicate("x", 500)
        })
        |> Repo.update!()

      assert {:ok, abandoned} = Operations.abandon_stuck_job(job.id, "andreas")
      assert String.length(abandoned.last_error) <= 500
      assert abandoned.last_error =~ "Abandoned by andreas"
    end

    test "refuses while a verifier still holds a live claim" do
      %{job: job} = running_job_fixture("working")

      claimed =
        job
        |> Job.changeset(%{
          state: "verifying_result",
          result_attempt_token: "live-attempt",
          result_attempt_expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
        })
        |> Repo.update!()

      assert {:error, :verification_in_progress} =
               Operations.abandon_stuck_job(claimed.id, "andreas")

      # Once that claim has expired, nothing is running and it can be ended.
      expired =
        claimed
        |> Job.changeset(%{
          result_attempt_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })
        |> Repo.update!()

      assert {:ok, _job} = Operations.abandon_stuck_job(expired.id, "andreas")
    end
  end

  describe "agent stop reports" do
    setup do
      previous = Application.get_env(:ptc_manager, :agent_action_output_dir)
      directory = Path.join(System.tmp_dir!(), "ptc-stop-#{System.unique_integer([:positive])}")
      File.mkdir_p!(directory)
      Application.put_env(:ptc_manager, :agent_action_output_dir, directory)

      on_exit(fn ->
        File.rm_rf(directory)

        if is_nil(previous),
          do: Application.delete_env(:ptc_manager, :agent_action_output_dir),
          else: Application.put_env(:ptc_manager, :agent_action_output_dir, previous)
      end)

      :ok
    end

    test "reads a valid report and refuses anything else" do
      job = stoppable_job_fixture()

      assert StopReport.read(job) == :none
      assert StopReport.path_for(job) =~ job.stop_report_token

      write_stop_report(job, %{
        "reason_code" => "missing_prerequisite",
        "summary" => "OPENROUTER_API_KEY is not set in this workspace.",
        "detail" => "The recording step needs a live key and no environment file was found.",
        "prerequisite" => "OPENROUTER_API_KEY",
        "progress" => "none"
      })

      assert {:ok, report} = StopReport.read(job)
      assert report["reason_code"] == "missing_prerequisite"
      assert StopReport.prerequisite(report) == "OPENROUTER_API_KEY"
      assert StopReport.nothing_committed?(report)

      # A report PtcManager cannot understand is not a stop: the ordinary
      # "no usable result" path has to stay in charge.
      write_stop_report(job, %{"reason_code" => "because-i-said-so", "summary" => "x"})
      assert {:error, :invalid_stop_report} = StopReport.read(job)

      File.write!(StopReport.path_for(job), "not json at all")
      assert {:error, :invalid_stop_report} = StopReport.read(job)

      # Oversized, and anything that is not a plain file, is refused unread.
      File.write!(StopReport.path_for(job), String.duplicate("x", 40_000))
      assert {:error, :invalid_stop_report} = StopReport.read(job)

      File.rm!(StopReport.path_for(job))
      decoy = Path.join(System.tmp_dir!(), "ptc-stop-decoy-#{System.unique_integer([:positive])}")
      File.write!(decoy, Jason.encode!(stop_report_attrs()))
      File.ln_s!(decoy, StopReport.path_for(job))
      assert {:error, :invalid_stop_report} = StopReport.read(job)
      File.rm!(decoy)
    end

    test "a job with no issued token has no readable path at all" do
      %{job: job} = running_job_fixture("working")

      assert is_nil(job.stop_report_token)
      assert is_nil(StopReport.path_for(job))
      assert StopReport.read(job) == :none
    end

    test "the reason decides which recoveries exist and which comes first" do
      assert StopReport.primary_action("missing_prerequisite") == :retry
      assert StopReport.primary_action("environment_broken") == :retry
      assert StopReport.primary_action("ambiguous_requirement") == :ask_on_issue

      # An agent calling something unsafe offers no recovery at all: restarting
      # it and rewording it are both ways of proceeding anyway.
      unsafe = %{"reason_code" => "unsafe_to_proceed"}
      assert StopReport.primary_action(unsafe) == :none
      assert StopReport.recoveries(unsafe) == []
      refute StopReport.allows?(unsafe, :retry)
      refute StopReport.allows?(unsafe, :ask_on_issue)

      assert StopReport.allows?(%{"reason_code" => "missing_prerequisite"}, :retry)
      assert StopReport.allows?(%{"reason_code" => "ambiguous_requirement"}, :retry)
    end

    test "recording a stop ends the attempt and frees the heavy slot" do
      %{run: run, allocation: allocation} = context = running_job_fixture("working")
      job = stoppable_job_fixture(context)
      report = stop_report_attrs()

      assert {:ok, stopped} =
               Operations.record_job_stop_report(
                 job.id,
                 job.fencing_token,
                 job.result_attempt_token,
                 report,
                 "coordinator"
               )

      assert stopped.state == "failed"
      assert stopped.ended_at
      assert stopped.stop_reported_at
      assert stopped.stop_report["prerequisite"] == "OPENROUTER_API_KEY"
      assert stopped.last_error == report["summary"]

      # A stopped agent must not keep holding capacity while it waits on a person.
      refute stopped.state in ~w(starting working idle blocked reconciling)

      assert Repo.get!(AgentRun, run.id).state == "lost"

      preserved = Repo.get!(WorktreeAllocation, allocation.id)
      assert preserved.state == "attention"

      audit = Repo.get_by!(AuditEvent, action: "job.agent_stopped")
      assert audit.details["reason_code"] == "missing_prerequisite"
    end

    test "a stale verifier cannot overwrite a newer result or a published job" do
      job = stoppable_job_fixture()
      report = stop_report_attrs()

      assert {:error, :stale_result_attempt} =
               Operations.record_job_stop_report(
                 job.id,
                 job.fencing_token,
                 "not-my-token",
                 report
               )

      assert {:error, :stale_result_attempt} =
               Operations.record_job_stop_report(
                 job.id,
                 job.fencing_token + 1,
                 job.result_attempt_token,
                 report
               )

      # A job that already published is past the point a verifier may end it.
      published =
        job |> Job.changeset(%{state: "pr_open"}) |> Repo.update!()

      assert {:error, :stale_result_attempt} =
               Operations.record_job_stop_report(
                 published.id,
                 published.fencing_token,
                 published.result_attempt_token,
                 report
               )

      assert Repo.get!(Job, job.id).state == "pr_open"
    end

    test "a stopped job stays on the delivery board until it is answered" do
      assert {:ok, stopped} = stop_job()

      assert [item] = Enum.filter(Operations.delivery_board_items(), & &1[:stopped?])
      assert item.active_job.id == stopped.id
      assert DeliveryLane.lane_for(item) == :stuck

      assert {:ok, _job} = Operations.acknowledge_job_stop(stopped.id, "andreas")
      assert Enum.filter(Operations.delivery_board_items(), & &1[:stopped?]) == []
      assert Repo.get_by!(AuditEvent, action: "job.stop_acknowledged")
    end

    test "dispatch failures stay visible and offer the existing explicit retry" do
      %{job: job, worker: worker, run: run} = running_job_fixture("starting")
      Repo.delete!(run)

      assert {:ok, failed} =
               Operations.mark_dispatch_failed(
                 job.id,
                 1,
                 worker.worker_key,
                 {:git_failed, "status", 128, "Cannot allocate memory"}
               )

      assert failed.stop_report["summary"] =~ "could not start"

      assert [%{active_job: %{id: id}}] =
               Enum.filter(Operations.delivery_board_items(), & &1[:stopped?])

      assert id == failed.id
      assert {:ok, retry} = Operations.retry_stopped_job(failed.id, "andreas")
      assert retry.approval_id == failed.approval_id
      assert retry.state == "queued"
    end

    test "retry refuses closed issues and newer attempts" do
      {:ok, stopped} = stop_job()
      issue = Repo.get!(Issue, stopped.issue_id)
      issue |> Ecto.Changeset.change(state: "closed") |> Repo.update!()
      assert {:error, :issue_not_open} = Operations.retry_stopped_job(stopped.id, "andreas")
      Repo.get!(Issue, issue.id) |> Ecto.Changeset.change(state: "open") |> Repo.update!()

      %Job{}
      |> Job.changeset(%{
        repository_id: stopped.repository_id,
        issue_id: stopped.issue_id,
        approval_id: stopped.approval_id,
        kind: stopped.kind,
        state: "queued"
      })
      |> Repo.insert!()

      assert {:error, :newer_job_exists} = Operations.retry_stopped_job(stopped.id, "andreas")
      assert is_nil(Repo.get!(Job, stopped.id).stop_acknowledged_at)
    end

    test "trying again reuses the approval and cannot run twice" do
      assert {:ok, stopped} = stop_job()

      assert {:ok, retry} = Operations.retry_stopped_job(stopped.id, "andreas")
      assert retry.id != stopped.id
      assert retry.state == "queued"
      assert retry.approval_id == stopped.approval_id
      assert retry.issue_id == stopped.issue_id
      assert retry.required_review_count == stopped.required_review_count
      assert retry.prompt_instructions == stopped.prompt_instructions
      assert retry.fencing_token == 0

      # The stopped card is answered, so pressing again cannot queue a second.
      assert {:error, :job_not_stopped} = Operations.retry_stopped_job(stopped.id, "andreas")
      assert Repo.get_by!(AuditEvent, action: "job.retried_after_stop")
    end

    test "a job that never stopped cannot be retried or set aside" do
      %{job: job} = running_job_fixture("working")

      assert {:error, :job_not_stopped} = Operations.retry_stopped_job(job.id, "andreas")
      assert {:error, :job_not_stopped} = Operations.acknowledge_job_stop(job.id, "andreas")
    end

    test "an unsafe stop refuses a retry even when the event is crafted by hand" do
      assert {:ok, stopped} =
               stop_job(%{
                 "reason_code" => "unsafe_to_proceed",
                 "summary" => "The change would delete data with no backup path.",
                 "detail" => "The issue asks for a destructive migration with no rollback.",
                 "progress" => "none"
               })

      assert {:error, :recovery_not_offered} =
               Operations.retry_stopped_job(stopped.id, "andreas")

      assert {:error, :recovery_not_offered} =
               MaintainerActions.enqueue_blocked_issue_review(stopped.id, "andreas")

      # Setting it aside is still allowed: that decides nothing.
      assert {:ok, _job} = Operations.acknowledge_job_stop(stopped.id, "andreas")
    end
  end

  describe "approve_issue_directly/3" do
    test "starts implementation without any proposal" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{title: "One-line typo"})

      assert {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas", 1)
      assert job.state == "queued"
      assert job.required_review_count == 1

      approval = Repo.get!(Approval, job.approval_id)
      assert approval.decision == "start_implementation_direct"
      assert is_nil(approval.proposal_id)
      assert is_nil(approval.proposal_digest)
      assert approval.source_digest == issue.content_digest
      assert approval.source_updated_at == issue.github_updated_at

      audit = Repo.get_by!(AuditEvent, action: "issue.approved_for_direct_implementation")
      assert audit.target_id == job.id
      assert is_nil(audit.details["proposal_id"])
    end

    test "uses Standard without a scope and risk assessment" do
      repository = repository_fixture(%{required_pre_pr_reviews: 3})
      issue = issue_fixture(repository)

      assert {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      assert job.required_review_count == 2
    end

    test "keeps every deterministic gate except the two proposal checks" do
      repository = repository_fixture()

      claimed =
        issue_fixture(repository, %{github_assignees: %{"logins" => ["someone-else"]}})

      assert {:error, :issue_claimed} =
               Operations.approve_issue_directly(claimed.id, "andreas")

      closed = issue_fixture(repository, %{state: "closed"})
      assert {:error, :issue_closed} = Operations.approve_issue_directly(closed.id, "andreas")

      blocked = issue_fixture(repository, %{workflow_label: "ptc:blocked"})

      assert {:error, :issue_workflow_not_ready} =
               Operations.approve_issue_directly(blocked.id, "andreas")

      conflicted = issue_fixture(repository, %{workflow_label_conflict: true})

      assert {:error, :issue_workflow_not_ready} =
               Operations.approve_issue_directly(conflicted.id, "andreas")

      dependent = issue_fixture(repository)
      blocker = issue_fixture(repository)
      dependency_fixture(dependent, blocker, repository)

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue_directly(dependent.id, "andreas")

      assert {:error, :invalid_review_count} =
               Operations.approve_issue_directly(issue_fixture(repository).id, "andreas", 6)
    end

    test "removing the repository also removes an approval that had no proposal" do
      repository = repository_fixture()
      issue = issue_fixture(repository)
      assert {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")

      job |> Job.changeset(%{state: "cancelled", ended_at: now()}) |> Repo.update!()

      Repo.update_all(PtcManager.Automations.Invocation, set: [state: "cancelled"])

      assert {:ok, _repository} = Operations.remove_repository(repository.id)
      assert Repo.aggregate(Approval, :count, :id) == 0
    end
  end

  describe "IssueLabels.toggle/4" do
    setup do
      previous_writer = Application.get_env(:ptc_manager, :issue_label_writer)
      previous_client = Application.get_env(:ptc_manager, :github_client)
      Application.put_env(:ptc_manager, :operations_label_test_pid, self())
      Application.put_env(:ptc_manager, :issue_label_writer, RecordingLabelWriter)
      Application.put_env(:ptc_manager, :github_client, LabelGitHubClient)

      on_exit(fn ->
        Application.put_env(:ptc_manager, :issue_label_writer, previous_writer)
        Application.put_env(:ptc_manager, :github_client, previous_client)

        for key <- [
              :operations_label_test_pid,
              :operations_label_result,
              :operations_label_remote_issue
            ],
            do: Application.delete_env(:ptc_manager, key)
      end)

      :ok
    end

    test "adds a configured label, audits it, and re-reads the issue from GitHub" do
      %{repository: repository, issue: issue, proposal: proposal} = labelled_issue()
      remote_answers(repository, issue, ["wait"])

      assert {:ok, :added} = IssueLabels.toggle(repository, issue, "wait", "andreas")
      assert_receive {:label_written, full_name, number, :add, "wait"}
      assert full_name == "#{repository.github_owner}/#{repository.github_name}"
      assert number == issue.number

      audit = Repo.get_by!(AuditEvent, action: "issue.label_added")
      assert audit.details["label"] == "wait"
      assert audit.actor == "andreas"

      synced = Repo.get!(Issue, issue.id)
      assert synced.github_labels == %{"names" => ["wait"]}
      refute synced.content_digest == issue.content_digest

      # A label write is GitHub activity like any other, and PtcManager cannot
      # tell it apart from a comment posted in the same second. The analysis
      # therefore goes stale rather than being blessed as still current.
      untouched = Repo.get!(Proposal, proposal.id)
      assert untouched.source_digest == proposal.source_digest
      assert untouched.source_updated_at == proposal.source_updated_at
      refute Repo.get_by(AuditEvent, action: "proposal.restamped_after_label_change")
    end

    test "refuses a reserved workflow label whatever its casing" do
      %{repository: repository, issue: issue} = labelled_issue()

      for name <- ["ptc:ready", "PTC:ready", "Ptc:Blocked"] do
        assert {:error, reason} = IssueLabels.toggle(repository, issue, name, "andreas")
        assert reason in [:reserved_label_name, :label_not_configured]
      end

      refute_receive {:label_written, _repository, _number, _operation, _label}
    end

    test "matches the configured label against GitHub casing when deciding add or remove" do
      %{repository: repository, issue: issue} = labelled_issue(github_labels: ["Wait"])
      remote_answers(repository, issue, [])

      assert {:ok, :removed} = IssueLabels.toggle(repository, issue, "wait", "andreas")
      assert_receive {:label_written, _full_name, _number, :remove, "wait"}
    end

    test "says so when the label reached GitHub but the re-read did not" do
      %{repository: repository, issue: issue} = labelled_issue()
      Application.put_env(:ptc_manager, :operations_label_remote_issue, {:error, :github_timeout})

      assert {:ok, :added, {:sync_failed, _reason}} =
               IssueLabels.toggle(repository, issue, "wait", "andreas")

      assert_receive {:label_written, _full_name, _number, :add, "wait"}
      assert Repo.get_by!(AuditEvent, action: "issue.label_added")
    end

    test "removes a label that GitHub already reports" do
      %{repository: repository, issue: issue} = labelled_issue(github_labels: ["wait"])
      remote_answers(repository, issue, [])

      assert {:ok, :removed} = IssueLabels.toggle(repository, issue, "wait", "andreas")
      assert_receive {:label_written, _full_name, _number, :remove, "wait"}
      assert Repo.get_by!(AuditEvent, action: "issue.label_removed")
    end

    test "refuses anything the maintainer did not configure" do
      %{repository: repository, issue: issue} = labelled_issue()

      assert {:error, :label_not_configured} =
               IssueLabels.toggle(repository, issue, "random", "andreas")

      assert {:error, :reserved_label_name} =
               IssueLabels.toggle(repository, issue, "ptc:ready", "andreas")

      closed = issue |> Issue.changeset(%{state: "closed"}) |> Repo.update!()
      assert {:error, :issue_closed} = IssueLabels.toggle(repository, closed, "wait", "andreas")

      refute_receive {:label_written, _repository, _number, _operation, _label}
    end

    test "a failed wrapper writes nothing and reports its exit status" do
      %{repository: repository, issue: issue} = labelled_issue()

      Application.put_env(
        :ptc_manager,
        :operations_label_result,
        {:error, {:label_wrapper_exit, 1}}
      )

      assert {:error, {:label_wrapper_exit, 1}} =
               IssueLabels.toggle(repository, issue, "wait", "andreas")

      assert Repo.get!(Issue, issue.id).github_labels == %{"names" => []}
      refute Repo.get_by(AuditEvent, action: "issue.label_added")
    end
  end

  describe "PlanningGroup.classify/2" do
    @now ~U[2026-09-04 12:00:00.000000Z]

    test "work that already started outranks every other signal" do
      assert group(planning_item(active_job: %{state: "working"})) == :in_delivery

      assert group(
               planning_item(
                 issue: %{workflow_label: "ptc:needs-decision"},
                 publication: %{state: "published", pr_state: "open"}
               )
             ) == :in_delivery

      assert group(planning_item(external_publication: %{pr_number: 7})) == :in_delivery
    end

    test "a parked label moves an otherwise ready issue out of the way" do
      item = planning_item(issue: %{github_labels: %{"names" => ["wait", "bug"]}})

      assert group(item) == :ready
      assert group(item, parked_labels: ["wait"]) == :waiting
    end

    test "parking matches GitHub casing" do
      item = planning_item(issue: %{github_labels: %{"names" => ["Wait"]}})

      assert group(item, parked_labels: ["wait"]) == :waiting

      assert group(planning_item(issue: %{github_labels: %{"names" => ["wait"]}}),
               parked_labels: ["WAIT"]
             ) == :waiting
    end

    test "a question for the maintainer is never hidden by parking" do
      parked = %{"names" => ["wait"]}

      assert group(
               planning_item(
                 issue: %{github_labels: parked, workflow_label: "ptc:needs-decision"}
               ),
               parked_labels: ["wait"]
             ) == :needs_decision

      assert group(
               planning_item(issue: %{github_labels: parked, workflow_label_conflict: true}),
               parked_labels: ["wait"]
             ) == :needs_decision

      assert group(
               planning_item(
                 issue: %{github_labels: parked},
                 issue_agent_action: %{state: "failed"}
               ),
               parked_labels: ["wait"]
             ) == :needs_decision
    end

    test "anything asking a question of the maintainer needs a decision" do
      assert group(planning_item(issue: %{workflow_label: "ptc:needs-decision"})) ==
               :needs_decision

      assert group(planning_item(issue: %{workflow_label_conflict: true})) == :needs_decision
      assert group(planning_item(dependency_cycle: [{"owner/repo", 1}])) == :needs_decision

      assert group(
               planning_item(
                 dependencies: [
                   %{lookup_state: "resolved", state: "closed", state_reason: "not_planned"}
                 ]
               )
             ) == :needs_decision

      assert group(planning_item(issue_agent_action: %{state: "failed"})) == :needs_decision
    end

    test "a fresh, ready, unclaimed issue is ready to start" do
      assert group(planning_item()) == :ready
      assert group(planning_item(issue: %{workflow_label: "ptc:ready"})) == :ready
    end

    test "GitHub or a dependency can block an otherwise ready issue" do
      assert group(planning_item(issue: %{workflow_label: "ptc:blocked"})) == :blocked
      assert group(planning_item(issue: %{dependencies_projected: false})) == :blocked
      assert group(planning_item(issue: %{dependency_overflow: true})) == :blocked
      assert group(planning_item(issue: %{dependency_unknown_count: 2})) == :blocked

      assert group(
               planning_item(
                 dependencies: [%{lookup_state: "resolved", state: "open", state_reason: nil}]
               )
             ) == :blocked
    end

    test "everything else has no usable analysis yet" do
      assert group(planning_item(proposal: nil)) == :not_prepared
      assert group(planning_item(proposal: %{readiness: "needs_information"})) == :not_prepared

      assert group(planning_item(issue: %{github_assignees: %{"logins" => ["x"]}})) ==
               :not_prepared
    end

    test "staleness replaces only the two groups nobody is waiting on" do
      old = DateTime.add(@now, -31 * 86_400, :second)

      assert group(planning_item(proposal: nil, issue: %{github_updated_at: old})) == :stale

      assert group(planning_item(issue: %{workflow_label: "ptc:blocked", github_updated_at: old})) ==
               :stale

      assert group(planning_item(issue: %{github_updated_at: old})) == :ready

      assert group(
               planning_item(
                 issue: %{workflow_label: "ptc:needs-decision", github_updated_at: old}
               )
             ) == :needs_decision
    end

    test "display order puts what you can do next first" do
      assert PlanningGroup.order() == [
               :ready,
               :needs_decision,
               :follow_ups,
               :not_prepared,
               :blocked,
               :in_delivery,
               :waiting,
               :stale
             ]
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

  describe "AgentHealth.assess/2" do
    @now ~U[2026-09-03 15:00:00.000000Z]

    defp health_run(attrs) do
      struct!(
        %AgentRun{
          role: "implementer",
          state: "working",
          started_at: @now,
          last_heartbeat_at: @now,
          state_changed_at: @now
        },
        attrs
      )
    end

    defp health_minutes_ago(count), do: DateTime.add(@now, -count * 60, :second)

    test "a working agent with a fresh Herdr signal is healthy" do
      assert %{status: :healthy, label: "Working"} =
               AgentHealth.assess(health_run(%{state_changed_at: health_minutes_ago(3)}), @now)
    end

    test "a retained agent held with its pull request is healthy" do
      assert %{status: :healthy, label: "Retained"} =
               AgentHealth.assess(
                 health_run(%{state: "waiting", state_changed_at: health_minutes_ago(600)}),
                 @now
               )
    end

    test "a briefly blocked agent is healthy because a turn may pause for input" do
      assert %{status: :healthy, label: "Asking for input"} =
               AgentHealth.assess(
                 health_run(%{state: "blocked", state_changed_at: health_minutes_ago(2)}),
                 @now
               )
    end

    # Herdr restores a pane after a server restart by running the agent without
    # its approval bypass, so it stops at a question and keeps a live heartbeat
    # while its pull request goes nowhere. Only the time spent in that one state
    # tells the two apart.
    test "an agent blocked past the grace period needs attention" do
      assert %{status: :attention, label: "Waiting for a person", detail: detail} =
               AgentHealth.assess(
                 health_run(%{state: "blocked", state_changed_at: health_minutes_ago(1_740)}),
                 @now
               )

      assert detail =~ "1d 5h"
      assert detail =~ "answer it in Herdr or cancel the agent"
    end

    test "an idle agent past the grace period needs attention too" do
      # Codex and Claude report idle, not blocked, when they end a turn with a
      # question. An idle agent that stopped moving is exactly as stuck.
      fresh = health_run(%{state: "idle", state_changed_at: health_minutes_ago(2)})
      assert AgentHealth.assess(fresh, @now).status == :healthy
      assert AgentHealth.assess(fresh, @now).label == "Idle"

      parked = health_run(%{state: "idle", state_changed_at: health_minutes_ago(120)})
      assessment = AgentHealth.assess(parked, @now)
      assert assessment.status == :attention
      assert assessment.label == "Waiting for a person"
      assert assessment.detail =~ "idle for"
      assert assessment.detail =~ "Nothing is watching its session"
    end

    test "a live heartbeat does not hide an agent Herdr stopped reporting" do
      assert %{status: :attention, label: "Out of contact"} =
               AgentHealth.assess(
                 health_run(%{state: "working", last_heartbeat_at: health_minutes_ago(45)}),
                 @now
               )
    end

    test "runs that ended badly need attention and a finished run does not" do
      assert %{status: :attention, label: "Ended without finishing"} =
               AgentHealth.assess(health_run(%{state: "failed"}), @now)

      assert %{status: :attention, label: "Lost from Herdr"} =
               AgentHealth.assess(health_run(%{state: "lost"}), @now)

      assert %{status: :ended} = AgentHealth.assess(health_run(%{state: "done"}), @now)
    end

    test "a run without a recorded state change falls back to when it started" do
      assert %{status: :attention, label: "Waiting for a person"} =
               AgentHealth.assess(
                 health_run(%{
                   state: "blocked",
                   state_changed_at: nil,
                   started_at: health_minutes_ago(120)
                 }),
                 @now
               )
    end

    test "needing_attention keeps only the runs a person has to look at" do
      healthy = health_run(%{state: "working"})
      blocked = health_run(%{state: "blocked", state_changed_at: health_minutes_ago(120)})

      assert AgentHealth.needing_attention([healthy, blocked], @now) == [blocked]
    end
  end

  defp labelled_issue(opts \\ []) do
    repository =
      repository_fixture(%{
        maintainer_labels: %{"labels" => [%{"name" => "wait", "role" => "park"}]}
      })

    body = "Decide later body"

    issue =
      issue_fixture(repository, %{
        title: "Decide later",
        body: body,
        body_digest: PtcManager.GitHub.IssueSnapshot.digest(body),
        github_labels: %{"names" => Keyword.get(opts, :github_labels, [])}
      })

    %{repository: repository, issue: issue, proposal: proposal_fixture(issue)}
  end

  defp remote_answers(repository, issue, label_names, opts \\ []) do
    Application.put_env(
      :ptc_manager,
      :operations_label_remote_issue,
      {:ok,
       %{
         "number" => issue.number,
         "title" => Keyword.get(opts, :title, issue.title),
         "html_url" => issue.html_url,
         "body" => issue.body,
         "state" => "open",
         "labels" => Enum.map(label_names, &%{"name" => &1}),
         "updated_at" =>
           issue.github_updated_at |> DateTime.add(5, :second) |> DateTime.to_iso8601(),
         "repository" => %{
           "full_name" => "#{repository.github_owner}/#{repository.github_name}"
         }
       }}
    )
  end

  defp group(item, opts \\ []),
    do: PlanningGroup.classify(item, Keyword.put_new(opts, :now, @now))

  # A dashboard item as `Operations.dashboard_issues/1` builds it, with only the
  # fields the classifier reads. An `:issue` or `:proposal` override is merged
  # into the ready default rather than replacing it.
  defp planning_item(overrides \\ []) do
    issue = %{
      state: "open",
      workflow_label: nil,
      workflow_label_conflict: false,
      github_assignees: %{"logins" => []},
      github_assignment_projected: true,
      dependencies_projected: true,
      dependency_overflow: false,
      dependency_unknown_count: 0,
      github_labels: %{"names" => []},
      content_digest: "digest",
      github_updated_at: @now
    }

    overrides = Map.new(overrides)
    issue = Map.merge(issue, Map.get(overrides, :issue, %{}))

    # The default analysis stays fresh for whatever issue the test asked for, so
    # a test about age is not accidentally a test about a stale proposal.
    proposal = %{
      readiness: "ready",
      source_digest: issue.content_digest,
      source_updated_at: issue.github_updated_at
    }

    %{
      issue: issue,
      proposal: merged_proposal(proposal, overrides),
      active_job: Map.get(overrides, :active_job),
      publication: Map.get(overrides, :publication),
      external_publication: Map.get(overrides, :external_publication),
      issue_agent_action: Map.get(overrides, :issue_agent_action),
      dependencies: Map.get(overrides, :dependencies, []),
      dependency_cycle: Map.get(overrides, :dependency_cycle)
    }
  end

  defp merged_proposal(_proposal, %{proposal: nil}), do: nil

  defp merged_proposal(proposal, overrides),
    do: Map.merge(proposal, Map.get(overrides, :proposal, %{}))

  defp stop_report_attrs do
    %{
      "reason_code" => "missing_prerequisite",
      "summary" => "OPENROUTER_API_KEY is not set in this workspace.",
      "detail" => "The recording step needs a live key and no environment file was found.",
      "prerequisite" => "OPENROUTER_API_KEY",
      "progress" => "none"
    }
  end

  defp write_stop_report(job, report) do
    File.write!(StopReport.path_for(job), Jason.encode!(report))
  end

  # A job as the reconciler holds it: claimed for verification, with its
  # stop-report capability issued.
  defp stoppable_job_fixture(context \\ nil) do
    %{job: job} = context || running_job_fixture("working")
    {:ok, job} = Operations.issue_stop_report_token(job)

    job
    |> Job.changeset(%{
      state: "verifying_result",
      result_attempt_token: "attempt-#{System.unique_integer([:positive])}",
      result_attempt_expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.update!()
  end

  defp stop_job(report \\ nil) do
    job = stoppable_job_fixture()

    Operations.record_job_stop_report(
      job.id,
      job.fencing_token,
      job.result_attempt_token,
      report || stop_report_attrs()
    )
  end

  defp running_job_fixture(state) do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    # Unique, so one test can build more than one running job.
    worker = worker_fixture(%{worker_key: "herdr:cancel-#{System.unique_integer([:positive])}"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    job =
      job
      |> Job.changeset(%{
        state: state,
        fencing_token: 1,
        lease_owner: worker.worker_key,
        lease_expires_at: DateTime.add(now, 600, :second),
        started_at: DateTime.add(now, -600, :second),
        branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}"
      })
      |> Repo.update!()

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "active",
        path: "/tmp/cancelled-agent-worktree",
        last_used_at: now
      })
      |> Repo.insert!()

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        started_at: job.started_at,
        last_heartbeat_at: now,
        herdr_workspace: "ptc-cancel",
        herdr_pane: "w7:p1",
        fencing_token: 1
      })

    %{job: job, run: run, allocation: allocation, worker: worker}
  end

  defp dependency_fixture(issue, blocker, repository) do
    issue_dependency_fixture(issue, %{
      blocking_issue: blocker,
      blocking_repository: repository
    })
  end
end
