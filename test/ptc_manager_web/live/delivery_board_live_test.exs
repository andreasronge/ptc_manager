defmodule PtcManagerWeb.DeliveryBoardLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations

  alias PtcManager.Operations.{AgentAction, AgentRun, Job, PrAnalysis, PrPublication}
  alias PtcManager.Publications
  alias PtcManager.Repo
  alias PtcManager.TestScenario

  defmodule ClosingHerdrClient do
    def list_agents, do: {:ok, []}

    def close_pane(pane_id) do
      send(Application.fetch_env!(:ptc_manager, :board_cancel_test_pid), {:closed, pane_id})
      :ok
    end
  end

  test "a waiting continuation is queued and a reserved continuation shows progress", %{
    conn: conn
  } do
    job = approved_job("Continue retained work") |> set_job_state("blocked")

    job =
      job
      |> Job.changeset(%{review_state: "resume_pending", review_resume_expires_at: nil})
      |> Repo.update!()

    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/board")
    assert has_element?(view, "#lane-queued #board-job-#{job.id}", "Continuation queued")
    refute has_element?(view, "#lane-stuck #board-job-#{job.id}")

    job
    |> Job.changeset(%{review_resume_expires_at: DateTime.add(DateTime.utc_now(), 600)})
    |> Repo.update!()

    Operations.notify_changed(:test)
    assert has_element?(view, "#lane-working #board-job-#{job.id}", "Continuation starting")
  end

  test "a paused review has a clear decision link even during reconciliation", %{conn: conn} do
    job = approved_job("Decide on remaining findings") |> set_job_state("reconciling")

    job
    |> Job.changeset(%{
      review_state: "paused",
      last_error: "A terminal managed agent identity became active again."
    })
    |> Repo.update!()

    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/board")
    assert has_element?(view, "#board-job-#{job.id}", "Review paused")
    refute has_element?(view, "#board-job-#{job.id}", "reconciling")
    assert has_element?(view, "#board-job-#{job.id}", "Review needs your decision")

    assert has_element?(
             view,
             "#job-reviews-#{job.id}[href='/jobs/#{job.id}/reviews']",
             "Review findings and decide"
           )

    assert has_element?(view, "#phase-error-board-job-#{job.id}", "terminal managed agent")
    refute has_element?(view, "#board-job-#{job.id}", "cannot yet confirm")
    view |> element("#job-reviews-#{job.id}") |> render_click()
    assert_redirect(view, "/jobs/#{job.id}/reviews")
  end

  test "a stale running-review flag does not hide reconciliation", %{conn: conn} do
    job = approved_job("Review outcome unknown") |> set_job_state("reconciling")
    job |> Job.changeset(%{review_state: "running"}) |> Repo.update!()
    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/board")
    assert has_element?(view, "#lane-stuck #board-job-#{job.id}", "cannot yet confirm")
    refute has_element?(view, "#board-job-#{job.id}", "Under review")
    refute has_element?(view, "#board-job-#{job.id}", "No decision is needed yet")
  end

  test "a running review links to progress without requesting a decision", %{conn: conn} do
    job = approved_job("Review underway") |> set_job_state("blocked")
    job |> Job.changeset(%{review_state: "running"}) |> Repo.update!()
    blocked_agent_run(job, "waiting-for-review")
    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/board")
    assert has_element?(view, "#lane-working #board-job-#{job.id}", "Under review")
    refute has_element?(view, "#lane-stuck #board-job-#{job.id}")
    refute has_element?(view, "#agent-attention-board-job-#{job.id}")
    assert has_element?(view, "#job-reviews-#{job.id}", "View review progress")
    assert has_element?(view, "#board-job-#{job.id}", "No decision is needed yet")
    refute has_element?(view, "#board-job-#{job.id}", "Review findings and decide")
  end

  test "separates queued, working, and blocked deliveries", %{conn: conn} do
    queued = approved_job("Queue this change")
    working = approved_job("Implement this change") |> set_job_state("working")
    blocked = approved_job("Repair this change") |> set_job_state("blocked")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-queued #board-job-#{queued.id}", "Queue this change")
    assert has_element?(view, "#lane-working #board-job-#{working.id}", "Implement this change")
    assert has_element?(view, "#lane-stuck #board-job-#{blocked.id}", "Repair this change")
    refute has_element?(view, "#lane-review")
    assert has_element?(view, "#lane-ready")
  end

  test "shows deterministic acknowledgement loss and Herdr adoption without polling", %{
    conn: conn
  } do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    %{job: job} = TestScenario.approved_implementation!(scenario)
    :ok = TestScenario.dispatch_outcome(scenario, :effect_then_error)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")
    assert has_element?(view, "#lane-queued #board-job-#{job.id}")

    assert {:error, :scenario_dispatch_ack_lost} = TestScenario.advance(scenario, :dispatch)
    assert has_element?(view, "#lane-stuck #board-job-#{job.id}")

    assert has_element?(
             view,
             "#lane-stuck #board-job-#{job.id}",
             "PtcManager cannot yet confirm the agent outcome."
           )

    assert {:ok, %{agent_count: 1}} = TestScenario.advance(scenario, :herdr_sync)
    assert has_element?(view, "#lane-working #board-job-#{job.id}")
    assert has_element?(view, "#board-job-#{job.id}", "Agent working")
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

  test "moves open pull requests between progress, attention, and ready-to-merge", %{conn: conn} do
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

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#lane-working #board-job-#{review_job.id}", "CI is still running")

    assert has_element?(
             view,
             "#lane-working #board-job-#{blocked_while_running_job.id}",
             "CI is still running"
           )

    assert has_element?(view, "#lane-stuck #board-job-#{stuck_job.id}", "Merge conflicts")

    assert has_element?(
             view,
             "#lane-ready #board-job-#{ready_job.id}",
             "All observed gates are clean"
           )

    assert has_element?(view, "#approve-merge-board-#{ready_publication.id}", "Approve and merge")
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
    assert action.prompt =~ "merge this PR when it is green and mergeable"
    assert action.prompt =~ ~s(merge_authorized="true")
    assert action.prompt =~ ~s(retained_workspace="true")

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
    assert has_element?(view, "#approve-merge-board-#{publication.id}", "Approve and merge")

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

    refute has_element?(view, "#repair-pr-#{failing.id}", "Fix")
    assert has_element?(view, "#repair-and-merge-pr-#{failing.id}", "Fix and merge")

    assert has_element?(
             view,
             "#lane-ready #board-pr-#{clean.id}",
             "Approve an agent to merge this pull request"
           )

    refute has_element?(view, "#retro-pr-#{clean.id}")
    refute has_element?(view, "#review-for-merge-#{clean.id}")
    assert has_element?(view, "#approve-merge-board-#{clean.id}", "Approve and merge")

    view |> element("#repair-and-merge-pr-#{failing.id}") |> render_click()

    assert Repo.get_by!(AgentAction, action_key: "repair_and_merge_pr", target_id: failing.id).state ==
             "queued"
  end

  # A retained agent parked at a question keeps a live Herdr heartbeat, so the
  # card used to blame the pull request for standing still while every action
  # queued against it failed a second later.
  test "names the stalled agent holding a pull request instead of blaming the PR", %{conn: conn} do
    job = approved_job("Repair the conflicted pull request") |> set_job_state("pr_open")
    publication = publication_fixture(job, "failure", "conflicting")
    blocked_agent_run(job, "impl_j#{job.id}_f1")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    card = "#lane-stuck #board-job-#{job.id}"

    assert has_element?(view, card, "Waiting for a person")
    assert has_element?(view, "#agent-attention-board-job-#{job.id}", "impl_j#{job.id}_f1")
    assert has_element?(view, card, "answer it in Herdr or cancel the agent")
    assert has_element?(view, card, "fail until it can run again")
    refute has_element?(view, card, "Merge conflicts must be resolved")

    assert has_element?(view, "#repair-and-merge-pr-#{publication.id}", "Fix and merge")
  end

  test "cancels a running implementation agent in two deliberate steps", %{conn: conn} do
    previous = Application.get_env(:ptc_manager, :herdr_client)
    Application.put_env(:ptc_manager, :board_cancel_test_pid, self())
    Application.put_env(:ptc_manager, :herdr_client, ClosingHerdrClient)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :herdr_client, previous)
      Application.delete_env(:ptc_manager, :board_cancel_test_pid)
    end)

    job = approved_job("Stop this agent") |> set_job_state("working")
    run = blocked_agent_run(job, "impl_j#{job.id}_f1")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#cancel-agent-#{job.id}")
    refute has_element?(view, "#confirm-cancel-agent-#{job.id}")

    view |> element("#cancel-agent-#{job.id}") |> render_click()

    assert has_element?(view, "#confirm-cancel-agent-#{job.id}", "Confirm cancel")
    assert Repo.get!(Job, job.id).state == "working"

    view |> element("#confirm-cancel-agent-#{job.id}") |> render_click()

    assert_receive {:closed, "w1:p1"}
    assert Repo.get!(Job, job.id).state == "cancelled"
    assert Repo.get!(AgentRun, run.id).state == "lost"
    refute has_element?(view, "#board-job-#{job.id}")
  end

  test "offers no cancel once PtcManager owns the remaining delivery steps", %{conn: conn} do
    job = approved_job("Verify this change") |> set_job_state("verifying_result")
    blocked_agent_run(job, "impl_j#{job.id}_f1")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#board-job-#{job.id}")
    refute has_element?(view, "#cancel-agent-#{job.id}")
  end

  test "marks a pull request whose retrospective asked for follow-up work", %{conn: conn} do
    job = approved_job("Shipped with loose ends") |> set_job_state("working")
    publication = publication_fixture(job, "success", "mergeable")

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    refute has_element?(view, "#follow-ups-suggested-board-job-#{job.id}")

    publication
    |> PrPublication.changeset(%{labels: %{"names" => ["ptc:follow-up"]}})
    |> Repo.update!()

    Operations.notify_changed(:test)

    assert has_element?(
             view,
             "#follow-ups-suggested-board-job-#{job.id}",
             "Follow-ups suggested"
           )
  end

  test "continuation hides the acknowledged stop while a later stop remains actionable", %{
    conn: conn
  } do
    report = %{
      "reason_code" => "environment_broken",
      "summary" => "The previous review was unavailable.",
      "detail" => "Work was preserved for continuation.",
      "progress" => "partial"
    }

    stopped = stop_job("Continue retained work", report)
    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/board")
    assert has_element?(view, "#agent-stopped-board-job-#{stopped.id}")

    {:ok, acknowledged} = Operations.acknowledge_job_stop(stopped.id, "maintainer")

    resumed =
      acknowledged
      |> Job.changeset(%{
        state: "working",
        review_state: "changes_requested",
        last_error: nil,
        ended_at: nil
      })
      |> Repo.update!()

    Operations.notify_changed(:test)

    assert has_element?(view, "#lane-working #board-job-#{stopped.id}")

    for selector <- [
          "agent-stopped-board-job",
          "retry-stopped",
          "ask-on-issue",
          "acknowledge-stop"
        ] do
      refute has_element?(view, "##{selector}-#{stopped.id}")
    end

    refute has_element?(view, "#board-job-#{stopped.id}", report["summary"])
    assert Repo.get!(Job, stopped.id).stop_report == report

    report_stop(resumed, %{report | "summary" => "A new prerequisite failed."})
    Operations.notify_changed(:test)

    assert has_element?(
             view,
             "#agent-stopped-board-job-#{stopped.id}",
             "A new prerequisite failed."
           )

    assert has_element?(view, "#retry-stopped-#{stopped.id}")
  end

  test "a stopped agent explains itself and offers the right recovery first", %{conn: conn} do
    stopped =
      stop_job("Record a live session", %{
        "reason_code" => "missing_prerequisite",
        "summary" => "OPENROUTER_API_KEY is not set in this workspace.",
        "detail" => "The recording step needs a live key and no env file was found.",
        "prerequisite" => "OPENROUTER_API_KEY",
        "progress" => "none"
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    card = "#lane-stuck #board-job-#{stopped.id}"
    assert has_element?(view, card, "Work stopped · Missing prerequisite")
    assert has_element?(view, card, "OPENROUTER_API_KEY is not set")
    assert has_element?(view, card, "committed nothing")
    # The technical branch error must not replace the agent's own explanation.
    refute has_element?(view, card, "The agent stopped before completing the task.")

    # A missing prerequisite is a retry, so Try again is the filled button.
    assert has_element?(view, "#retry-stopped-#{stopped.id}.bg-teal-400")
    refute has_element?(view, "#ask-on-issue-#{stopped.id}.bg-amber-300")

    view |> element("#retry-stopped-#{stopped.id}") |> render_click()

    assert render(view) =~ "Queued a fresh attempt"
    retry = Repo.get_by!(Job, state: "queued", issue_id: stopped.issue_id)
    assert retry.approval_id == stopped.approval_id
    refute has_element?(view, "#board-job-#{stopped.id}")
  end

  test "an ambiguity is offered to the issue first, not retried", %{conn: conn} do
    stopped =
      stop_job("Decide the export shape", %{
        "reason_code" => "ambiguous_requirement",
        "summary" => "The issue does not say which export shape to use.",
        "detail" => "Two incompatible readings, and no test distinguishes them.",
        "progress" => "partial"
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#board-job-#{stopped.id}", "Work stopped · Needs a decision")
    assert has_element?(view, "#board-job-#{stopped.id}", "worktree is kept")
    assert has_element?(view, "#ask-on-issue-#{stopped.id}.bg-amber-300")
    refute has_element?(view, "#retry-stopped-#{stopped.id}.bg-teal-400")

    view |> element("#ask-on-issue-#{stopped.id}") |> render_click()

    assert render(view) =~ "put the blocker on the GitHub issue"

    # A dedicated action, not issue preparation: its own prompt permits only a
    # comment and a blocked or needs-decision label, so the restriction binds
    # before the agent touches GitHub rather than after.
    queued = Repo.get_by!(AgentAction, action_key: "report_issue_blocker", state: "queued")
    assert queued.target_id == stopped.issue_id
    assert queued.prompt =~ "blocked_implementation"
    assert queued.prompt =~ "The issue does not say which export shape to use."
    assert queued.prompt =~ ~s(allowed_outcomes="blocked,needs-decision")
    refute queued.prompt =~ "reject"
    assert queued.target_snapshot == %{"allowed_outcomes" => ["blocked", "needs-decision"]}
    refute Repo.get_by(AgentAction, action_key: "prepare_issue")
    refute has_element?(view, "#board-job-#{stopped.id}")
  end

  test "an unsafe stop offers no filled recovery at all", %{conn: conn} do
    stopped =
      stop_job("Delete the archive", %{
        "reason_code" => "unsafe_to_proceed",
        "summary" => "The change would delete data with no backup path.",
        "detail" => "The issue asks for a destructive migration with no rollback.",
        "progress" => "none"
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#board-job-#{stopped.id}", "Work stopped · Judged unsafe")
    assert has_element?(view, "#board-job-#{stopped.id}", "Read the evidence before restarting")

    # Not merely unfilled: neither recovery exists to be clicked at all.
    refute has_element?(view, "#retry-stopped-#{stopped.id}")
    refute has_element?(view, "#ask-on-issue-#{stopped.id}")

    view |> element("#acknowledge-stop-#{stopped.id}") |> render_click()

    assert render(view) =~ "Set aside"
    refute has_element?(view, "#board-job-#{stopped.id}")
  end

  test "a job stuck in checking shows why and can be abandoned", %{conn: conn} do
    job = approved_job("Record a live session") |> set_job_state("working")

    stuck =
      job
      |> Job.changeset(%{state: "awaiting_reconciliation", last_error: ":no_commits"})
      |> Repo.update!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    card = "#board-job-#{stuck.id}"

    # A reconciliation that could not take the branch is not progress. Leaving
    # the card in "In progress" is how a Codex session parked at an unanswered
    # prompt stayed invisible for half an hour while its work sat uncommitted.
    assert has_element?(view, "#lane-stuck #{card}")
    refute has_element?(view, "#lane-working #{card}")

    # The reason has to be on the card, not only in the database.
    assert has_element?(view, "#phase-error-board-job-#{stuck.id}", ":no_commits")
    assert render(view) =~ "Read the agent&#39;s Herdr session before discarding the worktree"

    # There is no agent left to cancel, but there is a way out.
    refute has_element?(view, "#cancel-agent-#{stuck.id}")
    assert has_element?(view, "#abandon-job-#{stuck.id}", "Abandon")

    view |> element("#abandon-job-#{stuck.id}") |> render_click()
    assert has_element?(view, "#confirm-abandon-#{stuck.id}", "Confirm abandon")
    assert Repo.get!(Job, stuck.id).state == "awaiting_reconciliation"

    view |> element("#dismiss-abandon-#{stuck.id}") |> render_click()
    assert has_element?(view, "#abandon-job-#{stuck.id}")

    view |> element("#abandon-job-#{stuck.id}") |> render_click()
    view |> element("#confirm-abandon-#{stuck.id}") |> render_click()

    assert render(view) =~ "Abandoned."
    assert Repo.get!(Job, stuck.id).state == "cancelled"
    refute has_element?(view, card)
  end

  test "a job still reconciling without an error stays in progress", %{conn: conn} do
    job = approved_job("Reconciling cleanly") |> set_job_state("working")

    checking =
      job
      |> Job.changeset(%{state: "awaiting_reconciliation", last_error: nil})
      |> Repo.update!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    card = "#board-job-#{checking.id}"

    assert has_element?(view, "#lane-working #{card}")
    refute has_element?(view, "#lane-stuck #{card}")
  end

  test "a blocked publication with no pull request can still be abandoned", %{conn: conn} do
    job = approved_job("Blocked before publishing") |> set_job_state("working")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    head_sha = String.duplicate("b", 40)

    blocked =
      job
      |> Job.changeset(%{
        state: "publish_blocked",
        last_error: ":github_app_not_configured",
        result_base_sha: String.duplicate("a", 40),
        result_head_sha: head_sha,
        result_diff_digest: String.duplicate("c", 64),
        result_commit_count: 1,
        result_verified_at: now
      })
      |> Repo.update!()

    # The ordinary shape of this state: a publication row exists, but nothing
    # was ever published, so there is no pull request to orphan.
    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: blocked.id,
      state: "blocked",
      idempotency_key: String.duplicate("8", 64),
      fencing_token: blocked.fencing_token,
      branch_name: "ptc-manager/issue-job-#{blocked.id}",
      base_sha: String.duplicate("a", 40),
      head_sha: head_sha,
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      last_error: ":github_app_not_configured"
    })
    |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#abandon-job-#{blocked.id}", "Abandon")

    view |> element("#abandon-job-#{blocked.id}") |> render_click()
    view |> element("#confirm-abandon-#{blocked.id}") |> render_click()

    assert render(view) =~ "Abandoned."
    assert Repo.get!(Job, blocked.id).state == "cancelled"
  end

  test "a job whose verifier is still working offers no abandon", %{conn: conn} do
    job = approved_job("Still being checked") |> set_job_state("working")

    claimed =
      job
      |> Job.changeset(%{
        state: "verifying_result",
        result_attempt_token: "live-attempt",
        result_attempt_expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
      })
      |> Repo.update!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/board")

    assert has_element?(view, "#board-job-#{claimed.id}")
    refute has_element?(view, "#abandon-job-#{claimed.id}")
  end

  defp stop_job(title, report) do
    title |> approved_job() |> set_job_state("working") |> report_stop(report)
  end

  defp report_stop(job, report) do
    {:ok, job} = Operations.issue_stop_report_token(job)

    job =
      job
      |> Job.changeset(%{
        state: "verifying_result",
        result_attempt_token: "attempt-#{System.unique_integer([:positive])}",
        result_attempt_expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })
      |> Repo.update!()

    {:ok, stopped} =
      Operations.record_job_stop_report(
        job.id,
        job.fencing_token,
        job.result_attempt_token,
        report
      )

    stopped
  end

  defp approved_job(title) do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: title})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
    job
  end

  defp blocked_agent_run(job, agent_name) do
    worker = worker_fixture()
    stalled = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)

    %AgentRun{}
    |> AgentRun.changeset(%{
      worker_id: worker.id,
      job_id: job.id,
      role: "implementer",
      state: "blocked",
      agent_name: agent_name,
      herdr_pane: "w1:p1",
      fencing_token: 1,
      started_at: stalled,
      last_heartbeat_at: DateTime.utc_now(),
      state_changed_at: stalled
    })
    |> Repo.insert!()
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
