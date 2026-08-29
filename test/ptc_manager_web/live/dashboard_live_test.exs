defmodule PtcManagerWeb.DashboardLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.Job
  alias PtcManager.Repo

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
    assert html =~ "Explain remote failures"
    assert html =~ "Tracing the failure envelope"
    assert html =~ "Working for"
  end

  test "rejects a malformed approval target without crashing", %{conn: conn} do
    {:ok, view, _html} =
      conn
      |> authenticated_conn()
      |> live(~p"/")

    assert render_click(view, "approve", %{"issue-id" => "not-an-id"}) =~
             "That issue could not be found."
  end

  test "shows verified branch evidence before the draft PR gate", %{conn: conn} do
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

    assert has_element?(view, "#issue-#{issue.id}", "Ready for a draft PR")
    assert render(view) =~ "2 committed change(s) verified"
    assert render(view) =~ "GitHub is still unchanged"
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
           |> element("#agent-run-#{run.id}")
           |> render() =~ "2m 0s"
  end

  defp authenticated_conn(conn) do
    init_test_session(conn, %{authenticated: true, actor: "maintainer"})
  end
end
