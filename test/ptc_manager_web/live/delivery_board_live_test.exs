defmodule PtcManagerWeb.DeliveryBoardLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations

  alias PtcManager.Operations.{AgentAction, Job, PrAnalysis, PrPublication}
  alias PtcManager.Repo

  test "separates queued, working, and blocked deliveries", %{conn: conn} do
    queued = approved_job("Queue this change")
    working = approved_job("Implement this change") |> set_job_state("working")
    blocked = approved_job("Repair this change") |> set_job_state("blocked")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-queued #board-job-#{queued.id}", "Queue this change")
    assert has_element?(view, "#lane-working #board-job-#{working.id}", "Implement this change")
    assert has_element?(view, "#lane-stuck #board-job-#{blocked.id}", "Repair this change")
    assert has_element?(view, "#lane-review")
    assert has_element?(view, "#lane-ready")
  end

  test "moves open pull requests between review, attention, and ready-to-merge", %{conn: conn} do
    review_job = approved_job("Wait for CI") |> set_job_state("pr_open")
    _review_publication = publication_fixture(review_job, "pending", "mergeable")

    blocked_while_running_job =
      approved_job("Wait for required checks") |> set_job_state("pr_open")

    _blocked_while_running_publication =
      publication_fixture(blocked_while_running_job, "pending", "blocked")

    stuck_job = approved_job("Resolve conflicts") |> set_job_state("pr_open")
    _stuck_publication = publication_fixture(stuck_job, "success", "conflicting")

    ready_job = approved_job("Merge the finished change") |> set_job_state("pr_open")
    ready_publication = publication_fixture(ready_job, "success", "mergeable")
    analysis_fixture(ready_publication)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-review #board-job-#{review_job.id}", "CI is still running")

    assert has_element?(
             view,
             "#lane-review #board-job-#{blocked_while_running_job.id}",
             "CI is still running"
           )

    assert has_element?(view, "#lane-stuck #board-job-#{stuck_job.id}", "Merge conflicts")

    assert has_element?(
             view,
             "#lane-ready #board-job-#{ready_job.id}",
             "All observed gates are clean"
           )
  end

  test "queues a repair from Needs attention and shows queued work consistently", %{conn: conn} do
    job = approved_job("Repair the failing pull request") |> set_job_state("pr_open")
    publication = publication_fixture(job, "failure", "mergeable")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-stuck #board-job-#{job.id}")
    assert has_element?(view, "#repair-pr-#{publication.id}", "Fix CI or conflicts")

    view
    |> element("#repair-pr-#{publication.id}")
    |> render_click()

    action = Repo.get_by!(AgentAction, action_key: "repair_pr", target_id: publication.id)
    assert action.state == "queued"

    assert has_element?(
             view,
             "#board-job-#{job.id} [data-work-state=queued]",
             "Repair queued"
           )

    assert has_element?(view, "#repair-pr-#{publication.id}[disabled]")
  end

  defp approved_job(title) do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: title})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
    job
  end

  defp set_job_state(job, state) do
    job
    |> Job.changeset(%{
      state: state,
      started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      branch_name: "ptc-manager/issue-job-#{job.id}",
      fencing_token: 1,
      publication_source: "agent"
    })
    |> Repo.update!()
  end

  defp publication_fixture(job, checks_state, mergeability) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    base_sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    diff_digest = String.duplicate("c", 64)

    job
    |> Job.changeset(%{
      result_base_sha: base_sha,
      result_head_sha: head_sha,
      result_diff_digest: diff_digest,
      result_commit_count: 1,
      result_verified_at: now
    })
    |> Repo.update!()

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      state: "published",
      idempotency_key: String.duplicate(Integer.to_string(rem(job.id, 10)), 64),
      fencing_token: 1,
      branch_name: job.branch_name,
      base_sha: base_sha,
      head_sha: head_sha,
      diff_digest: diff_digest,
      attempt_count: 1,
      pr_number: 100 + job.id,
      pr_url: "https://github.com/owner/repo/pull/#{100 + job.id}",
      remote_head_sha: head_sha,
      remote_base_sha: base_sha,
      published_at: now,
      pr_state: "open",
      pr_checked_at: now,
      source: "agent",
      draft: false,
      checks_state: checks_state,
      checks_total: 1,
      checks_pending: if(checks_state == "pending", do: 1, else: 0),
      checks_failed: 0,
      mergeability: mergeability,
      mergeable_state: if(mergeability == "conflicting", do: "dirty", else: "clean")
    })
    |> Repo.insert!()
  end

  defp analysis_fixture(publication) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    publication = Repo.preload(publication, :job)

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: publication.job.repository_id,
        action_key: "prepare_merge_decision",
        target_type: "pull_request",
        target_id: publication.id,
        target_label: "PR ##{publication.pr_number}",
        prompt_version: 1,
        prompt: "Review the pull request",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "done",
        attempt_count: 1,
        requested_at: now,
        started_at: now,
        ended_at: now
      })
      |> Repo.insert!()

    %PrAnalysis{}
    |> PrAnalysis.changeset(%{
      publication_id: publication.id,
      agent_action_id: action.id,
      outcome: "merge-ready",
      plain_summary: "The change is ready.",
      why_it_matters: "The requested behavior is complete.",
      scope: "small",
      risk: "low",
      technical_evidence: "Tests and CI pass.",
      base_repository: "owner/repo",
      base_ref: "main",
      reviewed_base_sha: publication.remote_base_sha,
      head_repository: "owner/repo",
      head_ref: publication.branch_name,
      head_sha: publication.remote_head_sha,
      diff_digest: publication.diff_digest,
      analyzed_at: now
    })
    |> Repo.insert!()
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
