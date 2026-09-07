defmodule PtcManagerWeb.DeliveryReportLiveTest do
  use PtcManagerWeb.ConnCase, async: false
  alias PtcManager.{Operations, Repo}
  alias PtcManager.Operations.Job

  test "report remains readable on notifications and tabs expose missing measurements", %{
    conn: conn
  } do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 2, "small")

    {:ok, view, _} =
      conn
      |> init_test_session(%{authenticated: true, actor: "maintainer"})
      |> live("/jobs/#{job.id}/report")

    assert has_element?(view, "#report-summary", "No recorded reviews")
    view |> element("#report-tab-performance") |> render_click()
    assert has_element?(view, "#report-performance", "Not recorded")
    Operations.notify_changed(:test)
    assert has_element?(view, "#report-performance")
    view |> element("#report-tab-logbook") |> render_click()
    assert has_element?(view, "#report-logbook", "Implementation approved")
    view |> element("#report-tab-coverage") |> render_click()
    assert has_element?(view, "#report-coverage", "Unknown is never reported as zero")
    assert Repo.get!(Job, job.id).state == "queued"
  end
end
