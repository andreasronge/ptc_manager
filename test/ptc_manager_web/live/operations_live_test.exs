defmodule PtcManagerWeb.OperationsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations
  alias PtcManagerWeb.OperationsLive

  test "does not recommend another agent until every machine signal is available" do
    assert OperationsLive.capacity_tone(%{
             metrics: %{cpu_percent: nil, memory_percent: 20.0, disk_percent: 10.0},
             available_slots: 2
           }) == :unknown
  end

  test "shows machine capacity, workers, and an agent task timeline", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Add bounded result contracts"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")

    worker =
      worker_fixture(%{
        name: "Herdr build one",
        capabilities: %{"herdr" => true, "implementation_slots" => 2}
      })

    worker_fixture(%{
      name: "Old offline worker",
      status: "offline",
      capabilities: %{"herdr" => true, "implementation_slots" => 8}
    })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        agent_name: "impl_j#{job.id}_f1",
        started_at: DateTime.add(now, -120, :second),
        last_heartbeat_at: now
      })

    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/operations")

    assert html =~ "Capacity and agent history"
    assert has_element?(view, "#metric-cpu")
    assert has_element?(view, "#metric-memory")
    assert has_element?(view, "#metric-disk")
    assert has_element?(view, "#timeline-run-#{run.id}", "Add bounded result contracts")
    assert html =~ "Herdr build one"
    assert has_element?(view, "#metric-agents", "1 / 2")

    send(view.pid, :metrics_tick)
    assert render(view) =~ "configured slot(s) currently available"
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
