defmodule PtcManagerWeb.DeliveryBoardLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations

  alias PtcManager.Operations.{AgentAction, Job, PrAnalysis, PrPublication}
  alias PtcManager.Publications
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

  test "keeps cards in stable oldest-first order and shows their GitHub issues", %{conn: conn} do
    older = approved_job("Older issue") |> set_job_state("working")
    newer = approved_job("Newer issue") |> set_job_state("working")

    older_time = ~U[2026-08-30 10:00:00.000000Z]
    newer_time = ~U[2026-08-30 11:00:00.000000Z]

    older |> Job.changeset(%{started_at: older_time}) |> Repo.update!()
    newer |> Job.changeset(%{started_at: newer_time}) |> Repo.update!()

    older_issue = Repo.get!(PtcManager.Operations.Issue, older.issue_id)
    newer_issue = Repo.get!(PtcManager.Operations.Issue, newer.issue_id)

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/board")

    assert html =~ "GitHub issue"
    assert html =~ older_issue.html_url
    assert html =~ newer_issue.html_url

    {older_position, _} = :binary.match(html, "board-job-#{older.id}")
    {newer_position, _} = :binary.match(html, "board-job-#{newer.id}")
    assert older_position < newer_position
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

    needs_review_job = approved_job("Review the clean pull request") |> set_job_state("pr_open")
    needs_review_publication = publication_fixture(needs_review_job, "success", "mergeable")

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

    assert has_element?(view, "#lane-review #board-job-#{needs_review_job.id}")

    assert has_element?(
             view,
             "#review-for-merge-#{needs_review_publication.id}",
             "Review for merge"
           )

    view
    |> element("#review-for-merge-#{needs_review_publication.id}")
    |> render_click()

    assert Repo.get_by!(AgentAction,
             action_key: "prepare_merge_decision",
             target_id: needs_review_publication.id
           ).state == "queued"

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
    assert has_element?(view, "#repair-pr-#{publication.id}", "Fix")
    assert has_element?(view, "#repair-and-merge-pr-#{publication.id}", "Fix and merge")

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
    assert has_element?(view, "#repair-and-merge-pr-#{publication.id}[disabled]")
  end

  test "queues fix-and-merge as a distinct merge-priority action", %{conn: conn} do
    job = approved_job("Repair and merge the failing pull request") |> set_job_state("pr_open")
    publication = publication_fixture(job, "failure", "mergeable")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    view
    |> element("#repair-and-merge-pr-#{publication.id}")
    |> render_click()

    action =
      Repo.get_by!(AgentAction,
        action_key: "repair_and_merge_pr",
        target_id: publication.id
      )

    assert action.state == "queued"
    assert action.prompt =~ "same Herdr session"
    assert action.prompt =~ "Merge with the authenticated `gh` CLI"

    assert has_element?(
             view,
             "#board-job-#{job.id} [data-work-state=queued]",
             "Priority merge queued"
           )

    assert has_element?(
             view,
             "#queue-feedback-#{action.id}",
             "Safely stored in the priority merge queue"
           )
  end

  test "explains which running merge blocks a queued fix-and-merge action", %{conn: conn} do
    job = approved_job("Queue behind the current merge") |> set_job_state("pr_open")
    publication = publication_fixture(job, "failure", "conflicting")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    blocker =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: job.repository_id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: publication.id + 10_000,
        target_label: "owner/repo#1716",
        prompt_version: 1,
        prompt: "Fix and merge the earlier pull request",
        actor: "maintainer",
        state: "running",
        attempt_count: 1,
        requested_at: now,
        started_at: now
      })
      |> Repo.insert!()

    worker =
      worker_fixture(%{
        worker_key: "herdr:queue-feedback",
        name: "Herdr queue feedback",
        status: "online"
      })

    assert {:ok, _run} =
             Operations.create_agent_run(%{
               worker_id: worker.id,
               agent_action_id: blocker.id,
               role: "implementer",
               state: "working",
               status_text: "Fixing and merging PR #1716",
               started_at: now,
               last_heartbeat_at: now,
               fencing_token: 1
             })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    view
    |> element("#repair-and-merge-pr-#{publication.id}")
    |> render_click()

    queued =
      Repo.get_by!(AgentAction,
        action_key: "repair_and_merge_pr",
        target_id: publication.id
      )

    assert has_element?(view, "#queue-feedback-#{queued.id}", "Waiting for PR #1716")
    assert has_element?(view, "#queue-feedback-#{queued.id}", "one at a time")
  end

  test "shows a private retro on merge-ready work and creates only an approved suggestion", %{
    conn: conn
  } do
    job = approved_job("Merge and learn from this change") |> set_job_state("pr_open")
    publication = publication_fixture(job, "success", "mergeable")
    analysis_fixture(publication)
    retrospective = retrospective_action_fixture(publication)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-ready #board-job-#{job.id}")
    refute has_element?(view, "#retro-pr-#{publication.id}")
    assert has_element?(view, "#approve-merge-board-#{publication.id}", "Approve merge")

    assert has_element?(
             view,
             "#retro-suggestion-#{retrospective.id}-0",
             "A rare retry can still surprise users."
           )

    create_button = "#create-retro-issue-#{retrospective.id}-0"
    assert has_element?(view, create_button, "Add as GitHub issue")

    view |> element(create_button) |> render_click()

    creation =
      Repo.get_by!(AgentAction,
        action_key: "create_retrospective_issue",
        target_id: publication.id
      )

    assert creation.state == "queued"
    assert creation.target_snapshot["source_action_id"] == retrospective.id
    assert creation.target_snapshot["suggestion_index"] == 0
    assert has_element?(view, "#{create_button}[disabled]", "Issue queued")
  end

  test "shows external GitHub pull requests with repair but without retrospective", %{conn: conn} do
    repository = repository_fixture()
    linked_issue = issue_fixture(repository, %{number: 899, title: "Linked external issue"})

    assert {:ok, _summary} =
             Publications.sync_external_open_pull_requests(repository, [
               external_status(repository, 901, "failure", "conflicting")
               |> Map.put(:body, "Fixes #899"),
               external_status(repository, 902, "success", "mergeable")
             ])

    failing = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 901)
    clean = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 902)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-stuck #board-pr-#{failing.id}", "Imported from GitHub")

    assert has_element?(
             view,
             "#lane-stuck #board-pr-#{failing.id} a[href='#{linked_issue.html_url}']",
             "#899 · Linked external issue"
           )

    assert has_element?(view, "#repair-pr-#{failing.id}", "Fix")
    assert has_element?(view, "#repair-and-merge-pr-#{failing.id}", "Fix and merge")

    assert has_element?(
             view,
             "#lane-review #board-pr-#{clean.id}",
             "Review and merge this imported PR directly on GitHub"
           )

    refute has_element?(view, "#retro-pr-#{clean.id}")
    refute has_element?(view, "#review-for-merge-#{clean.id}")
    refute has_element?(view, "#approve-merge-board-#{clean.id}")

    view |> element("#repair-pr-#{failing.id}") |> render_click()

    assert Repo.get_by!(AgentAction, action_key: "repair_pr", target_id: failing.id).state ==
             "queued"
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
    publication = Repo.preload(publication, [:repository, :job])
    repository_id = publication.repository_id || publication.job.repository_id

    repository =
      publication.repository || Repo.get!(PtcManager.Operations.Repository, repository_id)

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository_id,
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
      base_repository: "#{repository.github_owner}/#{repository.github_name}",
      base_ref: repository.default_branch,
      reviewed_base_sha: publication.remote_base_sha,
      head_repository:
        publication.head_repository || "#{repository.github_owner}/#{repository.github_name}",
      head_ref: publication.branch_name,
      head_sha: publication.remote_head_sha,
      diff_digest: publication.diff_digest,
      analyzed_at: now
    })
    |> Repo.insert!()
  end

  defp external_status(repository, number, checks_state, mergeability) do
    head_sha = String.pad_leading(Integer.to_string(number, 16), 40, "b")

    %{
      pr_number: number,
      pr_url:
        "https://github.com/#{repository.github_owner}/#{repository.github_name}/pull/#{number}",
      state: "open",
      draft: false,
      title: "External PR #{number}",
      author_login: "external-author",
      body: "",
      head_sha: head_sha,
      head_ref: "external/pr-#{number}",
      head_repository: "#{repository.github_owner}/#{repository.github_name}",
      base_sha: String.duplicate("a", 40),
      base_ref: repository.default_branch,
      base_repository: "#{repository.github_owner}/#{repository.github_name}",
      mergeability: mergeability,
      mergeable_state: if(mergeability == "conflicting", do: "dirty", else: "clean"),
      checks_state: checks_state,
      checks_total: 1,
      checks_failed: if(checks_state == "failure", do: 1, else: 0),
      checks_pending: 0
    }
  end

  defp retrospective_action_fixture(publication) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    publication = Repo.preload(publication, job: :repository)

    result = %{
      "outcome" => "followups-proposed",
      "private_summary" => "One useful follow-up is worth considering.",
      "why_it_matters" => "It may prevent a future regression.",
      "scope" => "small",
      "risk" => "low",
      "technical_evidence" => "The retry edge case is not covered.",
      "github_changes" => [],
      "evidence" => ["Reviewed the pull request diff"],
      "created_issue_numbers" => [],
      "suggestions" => [
        %{
          "title" => "Investigate the unusual retry",
          "simple_summary" => "A rare retry can still surprise users.",
          "why_it_matters" => "It might repeat the bug in another path.",
          "category" => "potential-bug",
          "technical_evidence" => "No focused test covers the unusual retry.",
          "suggested_issue_body" => "Investigate the retry found while reviewing this PR."
        }
      ]
    }

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: publication.job.repository_id,
      action_key: "pr_retrospective",
      target_type: "pull_request",
      target_id: publication.id,
      target_label: "PR ##{publication.pr_number}",
      prompt_version: 1,
      prompt: "Review the pull request without changing GitHub",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "maintainer",
      state: "done",
      attempt_count: 1,
      requested_at: now,
      started_at: now,
      ended_at: now,
      result_summary: Jason.encode!(result)
    })
    |> Repo.insert!()
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
