defmodule PtcManagerWeb.DailyDigestLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.DailyDigests
  alias PtcManager.Operations.AgentAction
  alias PtcManager.Repo

  test "shows the no-backfill empty state and Updates navigation", %{conn: conn} do
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/updates")

    assert html =~ "What changed"
    assert has_element?(view, "nav", "Updates")
    assert has_element?(view, "#daily-digest-empty", "Daily updates are paused")
    assert html =~ "Published history remains available"
  end

  test "shows that generation is paused while history is retained", %{conn: conn} do
    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/updates")
    assert html =~ "Generation paused by default · history retained"
  end

  test "renders a published update and sanitizes model-generated Markdown", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "runner"})
    digest = digest_fixture(repository)

    assert {:ok, digest} =
             DailyDigests.publish(digest.agent_action, %{
               "status" => "published",
               "title" => "Build feedback became clearer",
               "summary" =>
                 "The command now explains what is missing instead of returning a misleading result.",
               "markdown" => """
               ## Fixed

               The command now names the missing attachment.

               **Before:** it returned `not found`.

               **After:** it suggests the exact attachment to add.

               <script>alert('unsafe')</script>

               ## References

               - [PR #1722](https://github.com/andreas/runner/pull/1722)
               """,
               "window_started_at" => DateTime.to_iso8601(digest.window_started_at),
               "window_ended_at" => DateTime.to_iso8601(digest.window_ended_at),
               "source_head_sha" => String.duplicate("c", 40),
               "change_count" => 1,
               "pull_request_numbers" => [1722]
             })

    {:ok, view, html} =
      conn |> authenticated_conn() |> live(~p"/updates/#{digest.id}")

    assert has_element?(view, "#daily-digest-#{digest.id}", "Build feedback became clearer")
    assert has_element?(view, "#daily-digest-detail", "Sunday, 30 August 2026")
    assert has_element?(view, "#daily-digest-markdown h2", "Fixed")
    assert has_element?(view, "#daily-digest-markdown", "Before:")
    assert has_element?(view, "#daily-digest-markdown a[href$='/pull/1722']", "PR #1722")
    assert html =~ "1 included change(s)"
    assert html =~ "1 pull request(s)"
    refute has_element?(view, "#daily-digest-markdown script")
    refute render(view) =~ "alert('unsafe')"
  end

  test "shows queued and failed generation state", %{conn: conn} do
    repository = repository_fixture()
    queued = digest_fixture(repository)

    {:ok, queued_view, _html} =
      conn |> authenticated_conn() |> live(~p"/updates/#{queued.id}")

    assert has_element?(queued_view, "#daily-digest-detail", "Queued")
    assert has_element?(queued_view, "#daily-digest-detail [class*='animate-spin']")

    queued.agent_action
    |> AgentAction.changeset(%{state: "failed", last_error: "agent stopped"})
    |> Repo.update!()

    send(queued_view.pid, {:operations_changed, :test})

    assert has_element?(queued_view, "#daily-digest-detail", "Generation failed")
    assert render(queued_view) =~ "inspected from Operations"
  end

  defp digest_fixture(repository) do
    enable_automation!(repository, "daily_digest")

    assert {:ok, digest} =
             DailyDigests.enqueue(repository, %{
               date: ~D[2026-08-30],
               time_zone: "Europe/Stockholm",
               started_at: ~U[2026-08-29 22:00:00Z],
               ended_at: ~U[2026-08-30 22:00:00Z]
             })

    digest
  end

  test "cancelled generation is terminal and does not promise a future report", %{conn: conn} do
    digest = repository_fixture() |> digest_fixture()

    digest.agent_action
    |> AgentAction.changeset(%{
      state: "cancelled",
      last_error: "Daily updates are disabled pending redesign."
    })
    |> Repo.update!()

    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/updates/#{digest.id}")
    assert has_element?(view, "#daily-digest-detail", "Generation cancelled")
    refute has_element?(view, "#daily-digest-detail [class*='animate-spin']")
    refute html =~ "waiting for the planning lane"
    refute html =~ "will update automatically"
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
