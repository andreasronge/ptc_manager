defmodule PtcManagerWeb.DailyDigestLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.DailyDigests
  alias PtcManager.Operations.AgentAction
  alias PtcManager.Repo

  test "shows the no-backfill empty state and Updates navigation", %{conn: conn} do
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/updates")

    assert html =~ "What changed"
    assert has_element?(view, "nav", "Updates")
    assert has_element?(view, "#daily-digest-empty", "first update arrives tomorrow morning")
    assert html =~ "no historical backfill"
  end

  test "shows the configured local generation schedule", %{conn: conn} do
    previous_hour = Application.get_env(:ptc_manager, :daily_digest_hour)
    previous_zone = Application.get_env(:ptc_manager, :daily_digest_time_zone)
    Application.put_env(:ptc_manager, :daily_digest_hour, 6)
    Application.put_env(:ptc_manager, :daily_digest_time_zone, "Europe/Helsinki")

    on_exit(fn ->
      Application.put_env(:ptc_manager, :daily_digest_hour, previous_hour)
      Application.put_env(:ptc_manager, :daily_digest_time_zone, previous_zone)
    end)

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/updates")
    assert html =~ "Generated after 06:00 Europe/Helsinki"
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
    assert {:ok, digest} =
             DailyDigests.enqueue(repository, %{
               date: ~D[2026-08-30],
               time_zone: "Europe/Stockholm",
               started_at: ~U[2026-08-29 22:00:00Z],
               ended_at: ~U[2026-08-30 22:00:00Z]
             })

    digest
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
