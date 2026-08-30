defmodule PtcManagerWeb.DashboardLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AgentAction,
    Issue,
    IssueDependency,
    Job,
    MergeApproval,
    PrAnalysis,
    PrPublication,
    WorktreeAllocation
  }

  alias PtcManager.Repo

  defmodule MergeApprovalClient do
    @behaviour PtcManager.GitHub.PullRequests

    def status(publication) do
      repository = publication.job.repository

      {:ok,
       %{
         pr_number: publication.pr_number,
         pr_url: publication.pr_url,
         state: "open",
         draft: false,
         body: "",
         head_sha: publication.remote_head_sha,
         head_ref: publication.branch_name,
         head_repository: "#{repository.github_owner}/#{repository.github_name}",
         base_sha: String.duplicate("d", 40),
         base_ref: repository.default_branch,
         base_repository: "#{repository.github_owner}/#{repository.github_name}"
       }}
    end
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
    |> element("#approve-issue-#{issue.id}")
    |> render_click()

    assert render(view) =~ "Job queued"
    assert Repo.one!(Job).issue_id == issue.id
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
      %IssueDependency{}
      |> IssueDependency.changeset(%{
        issue_id: dependent.id,
        blocking_issue_id: blocker.id,
        blocking_issue_number: blocker.number
      })
      |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(
             view,
             "#issue-#{dependent.id}-blocked-by-#{blocker.number}",
             "Blocked by ##{blocker.number} · open"
           )

    refute has_element?(view, "#issue-dependencies-#{dependent.id}", "All recorded blockers")

    blocker |> Issue.changeset(%{state: "closed"}) |> Repo.update!()
    Operations.notify_changed(:test)

    assert has_element?(
             view,
             "#issue-#{dependent.id}-blocked-by-#{blocker.number}",
             "Blocked by ##{blocker.number} · completed"
           )

    assert has_element?(
             view,
             "#issue-dependencies-#{dependent.id}",
             "Run Prepare issue again before approval"
           )

    assert dependency.blocking_issue_id == blocker.id
  end

  test "keeps approval disabled while a structured blocker is open", %{conn: conn} do
    repository = repository_fixture()
    blocker = issue_fixture(repository, %{number: 93})
    dependent = issue_fixture(repository, %{number: 94, workflow_label: "ptc:ready"})
    proposal_fixture(dependent)

    %IssueDependency{}
    |> IssueDependency.changeset(%{
      issue_id: dependent.id,
      blocking_issue_id: blocker.id,
      blocking_issue_number: blocker.number
    })
    |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(view, "#approve-issue-#{dependent.id}[disabled]")

    blocker |> Issue.changeset(%{state: "closed"}) |> Repo.update!()
    Operations.notify_changed(:test)

    refute has_element?(view, "#approve-issue-#{dependent.id}[disabled]")
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

  test "shows the private PR summary and records an exact-version merge approval", %{conn: conn} do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, MergeApprovalClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Approve only the reviewed PR"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    {_job, publication} = publication_fixture(job, "published")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, action} =
      Operations.enqueue_agent_action(%{
        repository_id: repository.id,
        action_key: "prepare_merge_decision",
        target_type: "pull_request",
        target_id: publication.id,
        target_label: "#{repository.github_owner}/#{repository.github_name}##73",
        prompt_version: 1,
        prompt: "Analyze the PR read-only.",
        actor: "andreas"
      })

    analysis =
      %PrAnalysis{}
      |> PrAnalysis.changeset(%{
        publication_id: publication.id,
        agent_action_id: action.id,
        outcome: "merge-ready",
        plain_summary: "The retry fix is small and ready to merge.",
        why_it_matters: "It prevents duplicate jobs.",
        scope: "small",
        risk: "low",
        technical_evidence: "Checks and reviews are green.",
        base_repository: "#{repository.github_owner}/#{repository.github_name}",
        base_ref: repository.default_branch,
        reviewed_base_sha: String.duplicate("d", 40),
        head_repository: "#{repository.github_owner}/#{repository.github_name}",
        head_ref: publication.branch_name,
        head_sha: publication.remote_head_sha,
        diff_digest: publication.diff_digest,
        analyzed_at: now
      })
      |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/")

    assert has_element?(view, "#pr-analysis-#{analysis.id}", "ready to merge")
    assert has_element?(view, "#approve-merge-#{publication.id}", "Approve for merge")

    view
    |> element("#approve-merge-#{publication.id}")
    |> render_click()

    assert render(view) =~ "Approved for merge at this exact PR version"
    assert render(view) =~ "Automatic merge is not enabled yet"

    approval = Repo.one!(MergeApproval)
    assert approval.pr_analysis_id == analysis.id
    assert approval.head_sha == publication.remote_head_sha
    assert approval.reviewed_base_sha == String.duplicate("d", 40)

    publication
    |> PrPublication.changeset(%{
      state: "blocked",
      remote_head_sha: String.duplicate("e", 40),
      last_error: "GitHub reports a different pull-request head commit."
    })
    |> Repo.update!()

    job
    |> Job.changeset(%{
      state: "publish_blocked",
      last_error: "GitHub reports a different pull-request head commit."
    })
    |> Repo.update!()

    send(view.pid, {:operations_changed, :test})

    assert render(view) =~ "The previous merge approval is stale"
    assert has_element?(view, "#pr-analysis-#{analysis.id}", "ready to merge")
  end

  test "offers a retrospective action after a pull request finishes", %{conn: conn} do
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

    assert has_element?(
             view,
             "#agent-action-pr_retrospective-pr-#{publication.id}",
             "Run retrospective"
           )

    view
    |> element("#agent-action-pr_retrospective-pr-#{publication.id}")
    |> render_click()

    assert render(view) =~ "PR retrospective queued for an agent"
    assert Repo.get_by!(AgentAction, action_key: "pr_retrospective").target_id == publication.id
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
