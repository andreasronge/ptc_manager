defmodule PtcManagerWeb.DashboardLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AgentAction,
    Issue,
    IssueDependency,
    Job,
    PrPublication,
    WorktreeAllocation
  }

  alias PtcManager.Repo

  test "filters Planning by repository from the URL" do
    first = repository_fixture(%{github_owner: "andreas", github_name: "first"})
    second = repository_fixture(%{github_owner: "andreas", github_name: "second"})
    first_issue = issue_fixture(first, %{title: "Only in first"})
    second_issue = issue_fixture(second, %{title: "Only in second"})
    proposal_fixture(first_issue)
    proposal_fixture(second_issue)
    {:ok, first_job} = Operations.approve_issue(first_issue.id, "maintainer")
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "maintainer")
    worker = worker_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, first_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: first_job.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now
      })

    {:ok, second_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: second_job.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now
      })

    {:ok, view, _html} =
      build_conn()
      |> authenticated_conn()
      |> live("/?repo=andreas%2Fsecond")

    assert has_element?(view, "#repository-selector option[selected]", "andreas/second")
    assert has_element?(view, "#issue-#{second_issue.id}", "Only in second")
    refute has_element?(view, "#issue-#{first_issue.id}")
    assert has_element?(view, "#agent-run-#{second_run.id}")
    refute has_element?(view, "#agent-run-#{first_run.id}")
    assert has_element?(view, "#active-agent-count", "1")

    {:ok, all_view, _html} =
      build_conn()
      |> authenticated_conn()
      |> live("/?repo=all")

    assert has_element?(all_view, "#repository-selector option[selected]", "All repositories")
    assert has_element?(all_view, "#issue-#{first_issue.id}")
    assert has_element?(all_view, "#issue-#{second_issue.id}")
    assert has_element?(all_view, "#agent-run-#{first_run.id}")
    assert has_element?(all_view, "#agent-run-#{second_run.id}")
    assert has_element?(all_view, "#active-agent-count", "2")
  end

  test "limits recent agent history after applying the repository filter" do
    first = repository_fixture(%{github_owner: "andreas", github_name: "history-first"})
    second = repository_fixture(%{github_owner: "andreas", github_name: "history-second"})
    worker = worker_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    first_issue = issue_fixture(first, %{title: "Older work in selected repository"})
    proposal_fixture(first_issue)
    {:ok, first_job} = Operations.approve_issue(first_issue.id, "maintainer")

    {:ok, first_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: first_job.id,
        role: "implementer",
        state: "done",
        started_at: DateTime.add(now, -120, :second),
        last_heartbeat_at: DateTime.add(now, -60, :second),
        ended_at: DateTime.add(now, -60, :second)
      })

    for offset <- 1..6 do
      issue = issue_fixture(second, %{title: "Newer other work #{offset}"})
      proposal_fixture(issue)
      {:ok, job} = Operations.approve_issue(issue.id, "maintainer")

      {:ok, _run} =
        Operations.create_agent_run(%{
          worker_id: worker.id,
          job_id: job.id,
          role: "implementer",
          state: "done",
          started_at: DateTime.add(now, -50 + offset, :second),
          last_heartbeat_at: DateTime.add(now, -40 + offset, :second),
          ended_at: DateTime.add(now, -40 + offset, :second)
        })
    end

    {:ok, view, _html} =
      build_conn()
      |> authenticated_conn()
      |> live("/?repo=andreas%2Fhistory-first")

    assert has_element?(view, "#agent-history-run-#{first_run.id}", "Older work")
    refute render(view) =~ "Newer other work"
  end

  test "approves a fresh issue and displays the queued job", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Keep retry evidence bounded"})
    proposal_fixture(issue)

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert has_element?(view, "#issue-#{issue.id}", "Keep retry evidence bounded")
    assert has_element?(view, "#approve-issue-#{issue.id}")

    view
    |> form("#approve-form-issue-#{issue.id}", %{
      "issue-id" => Integer.to_string(issue.id),
      "review-count" => "3"
    })
    |> render_submit()

    assert render(view) =~ "Job queued"
    job = Repo.one!(Job)
    assert job.issue_id == issue.id
    assert job.required_review_count == 3
    assert has_element?(view, "#job-review-count-#{job.id}", "3 review passes")
  end

  test "preserves the browser-managed technical evidence state across ticks", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert has_element?(view, "#technical-evidence-#{issue.id}[phx-mounted]")

    send(view.pid, :tick)

    assert has_element?(view, "#technical-evidence-#{issue.id}[phx-mounted]")
  end

  test "keeps action details open and turns a marked issue decision into choices", %{conn: conn} do
    repository = repository_fixture()

    issue =
      issue_fixture(repository, %{
        number: 1701,
        workflow_label: "ptc:needs-decision",
        workflow_label_conflict: false,
        body: "The GitHub issue contains the human-readable decision and its context."
      })

    proposal_fixture(issue, %{
      readiness: "needs_information",
      plain_summary: "Choose whether matching should be precise or only give a broad hint.",
      why_it_matters: "A broad hint could make a typo look like a real command."
    })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    completed =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "prepare_issue",
        target_type: "issue",
        target_id: issue.id,
        target_label: "issue #1701",
        prompt_version: 1,
        prompt: "Prepare issue",
        actor: "maintainer",
        state: "done",
        target_snapshot: %{
          "decision_issue_content_digest" => issue.content_digest,
          "source_sha" => String.duplicate("7", 40),
          "source_ref" => "main"
        },
        attempt_count: 1,
        requested_at: now,
        started_at: now,
        ended_at: now,
        result_summary:
          Jason.encode!(%{
            "outcome" => "needs-decision",
            "private_summary" =>
              "Choose whether matching should be precise or only give a broad hint.",
            "why_it_matters" => "A broad hint could make a typo look real.",
            "decision_question" =>
              "Should misses identify exact exports or only a shipped namespace?",
            "decision_options" => [
              %{
                "label" => "Exact export (preferred)",
                "description" => "Redirect only names that are real shipped commands.",
                "example" => "agent.core/run gets help; agent.core/typo stays an ordinary miss."
              },
              %{
                "label" => "Namespace hint",
                "description" => "Say only that the shipped library is not attached.",
                "example" => "A real name and a typo both receive the same broad hint."
              }
            ],
            "github_changes" => ["Added the marked decision section."],
            "evidence" => ["agent.core/typo demonstrates the difference."]
          })
      })
      |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-decision-#{issue.id}",
             "Should misses identify exact exports"
           )

    assert has_element?(view, "#issue-decision-#{issue.id}", "A — Exact export")
    assert has_element?(view, "#issue-decision-#{issue.id}", "agent.core/typo")
    assert has_element?(view, "#issue-decision-#{issue.id}", "B — Namespace hint")
    assert has_element?(view, "#custom-decision-answer-#{issue.id}")

    assert has_element?(
             view,
             "#agent-action-details-#{completed.id}[phx-mounted]",
             "Action details"
           )

    assert has_element?(
             view,
             "#agent-action-source-#{completed.id}",
             "Code evidence: main @ 7777777777"
           )

    send(view.pid, :tick)

    assert has_element?(view, "#agent-action-details-#{completed.id}[phx-mounted]")

    view
    |> form("#resolve-decision-form-#{issue.id}", %{
      "issue-id" => Integer.to_string(issue.id),
      "source-action-id" => Integer.to_string(completed.id),
      "decision" => %{"choice" => "0", "custom_answer" => ""}
    })
    |> render_submit()

    assert render(view) =~ "Your decision is queued for the agent to apply to GitHub"

    queued = Repo.get_by!(AgentAction, action_key: "resolve_issue_decision")
    assert queued.state == "queued"
    assert queued.target_snapshot["decision_answer"] =~ "Exact export"
    refute has_element?(view, "#issue-decision-refresh-#{issue.id}")
  end

  test "offers an explicit refresh for a legacy decision result without structured choices", %{
    conn: conn
  } do
    repository = repository_fixture()

    issue =
      issue_fixture(repository, %{
        workflow_label: "ptc:needs-decision",
        workflow_label_conflict: false
      })

    proposal_fixture(issue, %{readiness: "needs_information"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "prepare_issue",
      target_type: "issue",
      target_id: issue.id,
      target_label: "issue ##{issue.number}",
      prompt_version: 1,
      prompt: "Prepare issue",
      actor: "maintainer",
      state: "done",
      attempt_count: 1,
      requested_at: now,
      started_at: now,
      ended_at: now,
      result_summary:
        Jason.encode!(%{
          "outcome" => "needs-decision",
          "private_summary" => "A decision is needed.",
          "github_changes" => [],
          "evidence" => []
        })
    })
    |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-decision-refresh-#{issue.id}",
             "Decision choices need a refresh"
           )

    assert has_element?(view, "#issue-decision-refresh-#{issue.id}", "2–4 alternatives")

    view
    |> element("#issue-decision-refresh-#{issue.id} button", "Refresh decision choices")
    |> render_click()

    assert render(view) =~ "Prepare issue queued for an agent"
    assert Repo.get_by!(AgentAction, action_key: "prepare_issue", state: "queued")
  end

  test "explains that structured choices are stale after the GitHub issue changes", %{conn: conn} do
    repository = repository_fixture()

    issue =
      issue_fixture(repository, %{
        workflow_label: "ptc:needs-decision",
        workflow_label_conflict: false
      })

    proposal_fixture(issue, %{readiness: "needs_information"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "prepare_issue",
      target_type: "issue",
      target_id: issue.id,
      target_label: "issue ##{issue.number}",
      prompt_version: 1,
      prompt: "Prepare issue",
      actor: "maintainer",
      state: "done",
      target_snapshot: %{"decision_issue_content_digest" => issue.content_digest},
      attempt_count: 1,
      requested_at: now,
      started_at: now,
      ended_at: now,
      result_summary:
        Jason.encode!(%{
          "outcome" => "needs-decision",
          "decision_question" => "Which behavior should users get?",
          "decision_options" => [
            %{"label" => "A", "description" => "First", "example" => "One"},
            %{"label" => "B", "description" => "Second", "example" => "Two"}
          ]
        })
    })
    |> Repo.insert!()

    issue
    |> Issue.changeset(%{content_digest: String.duplicate("c", 64)})
    |> Repo.update!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-decision-refresh-#{issue.id}",
             "Issue changed since this decision was prepared"
           )

    assert has_element?(view, "#issue-decision-refresh-#{issue.id}", "newer issue content")
  end

  test "shows only open issues in the Issue inbox", %{conn: conn} do
    repository = repository_fixture()
    open_issue = issue_fixture(repository, %{title: "Still needs planning"})
    closed_issue = issue_fixture(repository, %{title: "Already completed", state: "closed"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(view, "#issue-#{open_issue.id}", "Still needs planning")
    refute has_element?(view, "#issue-#{closed_issue.id}")
  end

  test "shows a concise Codex failure without echoing issue content", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Retry the review"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "review_issue",
      target_type: "issue",
      target_id: issue.id,
      target_label: "issue ##{issue.number}",
      prompt_version: 1,
      prompt: "Review the issue",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "maintainer",
      state: "failed",
      attempt_count: 1,
      requested_at: now,
      started_at: now,
      ended_at: now,
      last_error: "Execution failed: {:codex_exit, 1, \"secret issue body invalid_json_schema\"}"
    })
    |> Repo.insert!()

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/")

    assert html =~ "Codex rejected the configured result format"
    refute html =~ "secret issue body"
  end

  test "describes an empty synchronized inbox as having no open work", %{conn: conn} do
    repository = repository_fixture()
    issue_fixture(repository, %{state: "closed"})

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/")

    assert html =~ "No open issues need planning."
    refute html =~ "No issues have been synchronized yet."
  end

  test "queues the hard-coded prepare issue action from the generic action button", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Decide the issue outcome"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#agent-action-prepare_issue-issue-#{issue.id}",
             "Prepare issue"
           )

    view
    |> element("#agent-action-prepare_issue-issue-#{issue.id}")
    |> render_click()

    assert render(view) =~ "Prepare issue queued for an agent"
    action = Repo.one!(AgentAction)
    assert action.action_key == "prepare_issue"
    assert action.target_id == issue.id
    assert has_element?(view, "#issue-#{issue.id}", "Agent action queued")
  end

  test "queues private analysis through the same durable Herdr action UI", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Explain this issue privately"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#agent-action-private_issue_analysis-issue-#{issue.id}",
             "Investigate privately"
           )

    view
    |> element("#agent-action-private_issue_analysis-issue-#{issue.id}")
    |> render_click()

    assert render(view) =~ "Private issue analysis queued for an agent"
    action = Repo.one!(AgentAction)
    assert action.action_key == "private_issue_analysis"
    assert action.state == "queued"
    assert has_element?(view, "#issue-#{issue.id}", "Agent action queued")
  end

  test "queues an independent issue review from the second issue action", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Challenge the issue before implementation"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#agent-action-review_issue-issue-#{issue.id}",
             "Review issue"
           )

    view
    |> element("#agent-action-review_issue-issue-#{issue.id}")
    |> render_click()

    assert render(view) =~ "Review issue queued for an agent"
    action = Repo.one!(AgentAction)
    assert action.action_key == "review_issue"
    assert action.target_id == issue.id
  end

  test "reports publication writes and read-only PR tracking independently", %{conn: conn} do
    previous_publication = Application.get_env(:ptc_manager, :publication_enabled)
    previous_reconciliation = Application.get_env(:ptc_manager, :pr_reconcile_enabled)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :publication_enabled, previous_publication)
      Application.put_env(:ptc_manager, :pr_reconcile_enabled, previous_reconciliation)
    end)

    Application.put_env(:ptc_manager, :publication_enabled, true)
    Application.put_env(:ptc_manager, :pr_reconcile_enabled, false)

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/")

    assert html =~ "Publication enabled · exact-SHA GitHub App broker"
    assert html =~ "Read-only PR status tracking disabled"
    refute html =~ "without GitHub writes"
  end

  test "reports agent-owned PR creation as an enabled GitHub write path", %{conn: conn} do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/")

    assert html =~ "New jobs use agent publication · authenticated worker creates the PR"
    refute html =~ "without GitHub writes"
  end

  test "shows who an agent is working for and since when", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Explain remote failures"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    worker = worker_fixture(%{name: "Hetzner build one"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        agent_name: "codex",
        status_text: "Tracing the failure envelope.",
        started_at: DateTime.add(now, -90, :second),
        last_heartbeat_at: now,
        herdr_workspace: "issue-#{issue.number}",
        herdr_pane: "w1:p1"
      })

    {:ok, _view, html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert html =~ "Hetzner build one"
    assert html =~ "codex"
    assert html =~ "Explain remote failures"
    assert html =~ "Tracing the failure envelope"
    assert html =~ "Working for"
  end

  test "shows an advisory GitHub claim and disables duplicate approval", %{conn: conn} do
    repository = repository_fixture()

    issue =
      issue_fixture(repository, %{
        title: "Work already started elsewhere",
        github_assignees: %{"logins" => ["outside-agent"]}
      })

    proposal_fixture(issue)
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-#{issue.id}-claimed",
             "Taken by @outside-agent"
           )

    assert has_element?(view, "#approve-issue-#{issue.id}[disabled]")
  end

  test "shows unknown claim state and disables approval before first sync", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{github_assignment_projected: false})
    proposal_fixture(issue)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-#{issue.id}-claim-unknown",
             "Claim status needs sync"
           )

    assert has_element?(view, "#approve-issue-#{issue.id}[disabled]")
  end

  test "shows linked dependency state and prompts re-review after completion", %{conn: conn} do
    repository = repository_fixture()
    blocker = issue_fixture(repository, %{number: 91, title: "Build the prerequisite"})

    dependent =
      issue_fixture(repository, %{
        number: 92,
        title: "Use the prerequisite",
        workflow_label: "ptc:blocked"
      })

    proposal_fixture(dependent, %{readiness: "needs_information"})

    dependency =
      issue_dependency_fixture(dependent, %{
        blocking_issue: blocker,
        blocking_repository: repository
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-#{dependent.id}-blocked-by-#{repository.github_owner}-#{repository.github_name}-#{blocker.number}",
             "Blocked by #{repository.github_owner}/#{repository.github_name}##{blocker.number} · open"
           )

    refute has_element?(view, "#issue-dependencies-#{dependent.id}", "All recorded blockers")

    blocker
    |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
    |> Repo.update!()

    dependency
    |> IssueDependency.changeset(%{
      blocking_state: "closed",
      blocking_state_reason: "completed"
    })
    |> Repo.update!()

    Operations.notify_changed(:test)

    assert has_element?(
             view,
             "#issue-#{dependent.id}-blocked-by-#{repository.github_owner}-#{repository.github_name}-#{blocker.number}",
             "Blocked by #{repository.github_owner}/#{repository.github_name}##{blocker.number} · completed"
           )

    assert has_element?(
             view,
             "#issue-dependencies-#{dependent.id}",
             "This issue can start when the other approval checks pass"
           )

    assert dependency.blocking_issue_id == blocker.id
  end

  test "keeps approval disabled while a structured blocker is open", %{conn: conn} do
    repository = repository_fixture()
    blocker = issue_fixture(repository, %{number: 93})
    dependent = issue_fixture(repository, %{number: 94, workflow_label: "ptc:ready"})
    proposal_fixture(dependent)

    dependency =
      issue_dependency_fixture(dependent, %{
        blocking_issue: blocker,
        blocking_repository: repository
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(view, "#approve-issue-#{dependent.id}[disabled]")

    blocker
    |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
    |> Repo.update!()

    dependency
    |> IssueDependency.changeset(%{
      blocking_state: "closed",
      blocking_state_reason: "completed"
    })
    |> Repo.update!()

    Operations.notify_changed(:test)

    refute has_element?(view, "#approve-issue-#{dependent.id}[disabled]")
  end

  test "shows a closed blocker with an unknown reason as needing a decision", %{conn: conn} do
    repository = repository_fixture()

    blocker =
      issue_fixture(repository, %{
        number: 95,
        state: "closed",
        github_state_reason: "completed"
      })

    dependent = issue_fixture(repository, %{number: 96, workflow_label: "ptc:ready"})
    proposal_fixture(dependent)

    issue_dependency_fixture(dependent, %{
      blocking_issue: blocker,
      blocking_repository: repository,
      blocking_state: "closed",
      blocking_state_reason: nil
    })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-dependencies-#{dependent.id}",
             "A prerequisite was closed without being completed"
           )

    assert has_element?(view, "#approve-issue-#{dependent.id}[disabled]")
  end

  test "shows dependency overflow and keeps approval disabled", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{dependency_overflow: true, workflow_label: "ptc:ready"})
    proposal_fixture(issue)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-dependencies-#{issue.id}",
             "More than 100 blockers were declared"
           )

    assert has_element?(view, "#approve-issue-#{issue.id}[disabled]")
  end

  test "shows an exact dependency cycle and keeps every issue blocked", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "owner", github_name: "application"})
    first = issue_fixture(repository, %{number: 201, workflow_label: "ptc:ready"})
    second = issue_fixture(repository, %{number: 202, workflow_label: "ptc:ready"})
    proposal_fixture(first)
    proposal_fixture(second)

    dependency_fixture(first, second, repository)
    dependency_fixture(second, first, repository)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-dependency-cycle-#{first.id}",
             "owner/application#201 → owner/application#202 → owner/application#201"
           )

    assert has_element?(view, "#approve-issue-#{first.id}[disabled]")
    assert has_element?(view, "#approve-issue-#{second.id}[disabled]")
  end

  test "keeps approval disabled for a cycle whose direct blocker is completed", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "owner", github_name: "cycle"})
    first = issue_fixture(repository, %{number: 211, workflow_label: "ptc:ready"})

    second =
      issue_fixture(repository, %{
        number: 212,
        state: "closed",
        github_state_reason: "completed"
      })

    proposal_fixture(first)
    dependency_fixture(first, second, repository)
    dependency_fixture(second, first, repository)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(view, "#issue-dependency-cycle-#{first.id}")
    assert has_element?(view, "#approve-issue-#{first.id}[disabled]")
  end

  test "shows an unsynchronized dependency projection and keeps approval disabled", %{conn: conn} do
    repository = repository_fixture()

    issue =
      issue_fixture(repository, %{
        dependencies_projected: false,
        workflow_label: "ptc:ready"
      })

    proposal_fixture(issue)
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-dependencies-#{issue.id}",
             "Dependency state has not been synchronized yet"
           )

    assert has_element?(view, "#approve-issue-#{issue.id}[disabled]")
  end

  test "explains blockers hidden from the GitHub reader", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{dependency_unknown_count: 2})
    proposal_fixture(issue)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-dependencies-#{issue.id}",
             "GitHub reports 2 blocker(s) that this account cannot inspect"
           )

    assert has_element?(view, "#approve-issue-#{issue.id}[disabled]")
  end

  test "shows only active agents and limits recent history to five ended runs", %{conn: conn} do
    worker = worker_fixture(%{name: "Hetzner build one"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, idle_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "implementer",
        state: "idle",
        status_text: "Waiting for work",
        started_at: DateTime.add(now, -300, :second),
        last_heartbeat_at: now
      })

    {:ok, active_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "implementer",
        state: "working",
        status_text: "Fixing the selected issue",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now
      })

    historical_runs =
      for number <- 1..6 do
        ended_at = DateTime.add(now, -number, :second)

        {:ok, run} =
          Operations.create_agent_run(%{
            worker_id: worker.id,
            role: "implementer",
            state: "done",
            status_text: "Historical run #{number}",
            started_at: DateTime.add(ended_at, -30, :second),
            last_heartbeat_at: ended_at,
            ended_at: ended_at
          })

        run
      end

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(view, "#active-agent-count", "1")
    assert has_element?(view, "#agent-run-#{active_run.id}", "Fixing the selected issue")
    refute has_element?(view, "#agent-run-#{idle_run.id}")

    for run <- Enum.take(historical_runs, 5) do
      assert has_element?(view, "#agent-history-run-#{run.id}")
    end

    oldest_run = List.last(historical_runs)
    refute has_element?(view, "#agent-history-run-#{oldest_run.id}")
    assert has_element?(view, "#agent-history", "Latest 5")
  end

  test "rejects a malformed approval target without crashing", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert render_click(view, "approve", %{"issue-id" => "not-an-id"}) =~
             "That issue could not be found."
  end

  test "shows verified branch evidence while waiting for publication", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Prepare a safe draft PR"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job
    |> Job.changeset(%{
      state: "ready_for_pr",
      result_base_sha: String.duplicate("a", 40),
      result_head_sha: String.duplicate("b", 40),
      result_diff_digest: String.duplicate("c", 64),
      result_commit_count: 2,
      result_verified_at: DateTime.utc_now()
    })
    |> Repo.update!()

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert has_element?(view, "#issue-#{issue.id}", "Waiting for publication")
    assert render(view) =~ "2 committed change(s) verified"
    assert render(view) =~ "Waiting safely until automatic publication is enabled"
  end

  test "links the canonical PR after publication", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Publish without another approval"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    {job, publication} = publication_fixture(job, "published")

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert has_element?(view, "#issue-#{issue.id}", "PR published")

    assert has_element?(
             view,
             "#publication-pr-#{publication.id}[href='#{publication.pr_url}']",
             "Open PR #73"
           )

    assert job.state == "pr_open"
  end

  test "does not queue a separate retrospective after a pull request finishes", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Learn from completed work"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    {job, publication} = publication_fixture(job, "published")

    job
    |> Job.changeset(%{state: "done", ended_at: DateTime.utc_now()})
    |> Repo.update!()

    publication
    |> PrPublication.changeset(%{pr_state: "merged"})
    |> Repo.update!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    refute has_element?(view, "#agent-action-pr_retrospective-pr-#{publication.id}")
    refute Repo.get_by(AgentAction, action_key: "pr_retrospective")
  end

  test "requeues a blocked publication from the dashboard", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Recover publishing safely"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    {job, publication} = publication_fixture(job, "blocked")

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert has_element?(view, "#retry-publication-#{publication.id}", "Retry publishing")

    view
    |> element("#retry-publication-#{publication.id}")
    |> render_click()

    assert render(view) =~ "PR publication is queued again"
    assert Repo.get!(PrPublication, publication.id).state == "queued"
    assert Repo.get!(Job, job.id).state == "ready_for_pr"
  end

  test "shows dynamic worktree usage against advertised implementation capacity", %{conn: conn} do
    worker =
      worker_fixture(%{
        name: "Hetzner agent pool",
        capabilities: %{"herdr" => true, "implementation_slots" => 3}
      })

    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job
    |> Job.changeset(%{state: "working", lease_owner: worker.worker_key})
    |> Repo.update!()

    %WorktreeAllocation{}
    |> WorktreeAllocation.changeset(%{
      worker_id: worker.id,
      job_id: job.id,
      state: "attention",
      path: "/tmp/uncertain-dashboard-slot",
      last_used_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/")

    assert html =~ "Hetzner agent pool"
    assert html =~ "Implementation worktrees"
    assert html =~ "1 / 3"
    assert Repo.get!(Operations.Worker, worker.id)
  end

  test "offers a safe manual retry while branch verification is pending", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job
    |> Job.changeset(%{
      state: "awaiting_reconciliation",
      fencing_token: 1,
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}",
      last_error: ":branch_missing"
    })
    |> Repo.update!()

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert has_element?(view, "#reconcile-job-#{job.id}", "Check committed branch")
    assert render(view) =~ "Branch verification is pending"
  end

  test "reloads agent activity after an external database change", %{conn: conn} do
    worker = worker_fixture()

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    refute has_element?(view, "#agent-activity", "Started outside LiveView")

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "manager",
        state: "working",
        status_text: "Started outside LiveView",
        started_at: now,
        last_heartbeat_at: now
      })

    assert render(view) =~ "Started outside LiveView"
  end

  test "stops elapsed time when an agent run ends", %{conn: conn} do
    worker = worker_fixture()
    started_at = ~U[2026-08-29 06:00:00.000000Z]
    ended_at = DateTime.add(started_at, 120, :second)

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "reviewer",
        state: "done",
        started_at: started_at,
        last_heartbeat_at: ended_at,
        ended_at: ended_at
      })

    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert view
           |> element("#agent-history-run-#{run.id}")
           |> render() =~ "2m 0s"
  end

  defp authenticated_conn(conn) do
    init_test_session(conn, %{authenticated: true, actor: "maintainer"})
  end

  defp dependency_fixture(issue, blocker, repository) do
    issue_dependency_fixture(issue, %{
      blocking_issue: blocker,
      blocking_repository: repository
    })
  end

  defp publication_fixture(job, state) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    base_sha = String.duplicate("a", 40)
    head_sha = String.duplicate("b", 40)
    diff_digest = String.duplicate("c", 64)
    job_state = if state == "published", do: "pr_open", else: "publish_blocked"

    job =
      job
      |> Job.changeset(%{
        state: job_state,
        fencing_token: 1,
        branch_name: "ptc-manager/issue-job-#{job.id}",
        result_base_sha: base_sha,
        result_head_sha: head_sha,
        result_diff_digest: diff_digest,
        result_commit_count: 2,
        result_verified_at: now,
        last_error: if(state == "blocked", do: ":github_app_not_configured")
      })
      |> Repo.update!()

    attrs = %{
      job_id: job.id,
      state: state,
      idempotency_key: String.duplicate("d", 64),
      fencing_token: job.fencing_token,
      branch_name: job.branch_name,
      base_sha: base_sha,
      head_sha: head_sha,
      diff_digest: diff_digest,
      attempt_count: 1,
      last_error: if(state == "blocked", do: ":github_app_not_configured"),
      pr_number: if(state == "published", do: 73),
      pr_url: if(state == "published", do: "https://github.com/owner/repo/pull/73"),
      remote_head_sha: if(state == "published", do: head_sha),
      remote_base_sha: if(state == "published", do: String.duplicate("d", 40)),
      published_at: if(state == "published", do: now),
      pr_state: if(state == "published", do: "open"),
      pr_checked_at: if(state == "published", do: now),
      source: "broker"
    }

    publication = %PrPublication{} |> PrPublication.changeset(attrs) |> Repo.insert!()
    {job, publication}
  end
end
