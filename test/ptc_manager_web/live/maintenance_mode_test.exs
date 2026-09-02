defmodule PtcManagerWeb.MaintenanceModeTest do
  use PtcManagerWeb.ConnCase, async: false

  import Plug.Conn

  alias PtcManager.Operations.Job
  alias PtcManager.Repo

  setup do
    previous = Application.get_env(:ptc_manager, :operational_mode)
    Application.put_env(:ptc_manager, :operational_mode, :maintenance)
    on_exit(fn -> restore_env(:operational_mode, previous) end)
    :ok
  end

  test "keeps planning readable but blocks a maintainer mutation", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Keep maintenance inspection safe"})
    proposal_fixture(issue)

    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/")

    assert html =~ "Keep maintenance inspection safe"
    assert has_element?(view, "#maintenance-mode-banner", "Maintenance mode")

    html =
      view
      |> form("#approve-form-issue-#{issue.id}", %{
        "issue-id" => Integer.to_string(issue.id),
        "review-count" => "1"
      })
      |> render_submit()

    assert html =~ "new work is paused"
    refute Repo.exists?(Job)
  end

  test "keeps Operations readable", %{conn: conn} do
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/operations")

    assert html =~ "Capacity right now"
    assert has_element?(view, "#maintenance-mode-banner", "Read-only inspection is available")
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
