defmodule PtcManagerWeb.AutomationsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Automations

  test "shows definitions, complete configuration, schedules, and run history", %{conn: conn} do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")
    trigger = Enum.find(definition.triggers, &(&1.trigger_type == "manual"))

    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/automations")

    assert html =~ "Automations"
    assert has_element?(view, "nav", "Automations")
    assert has_element?(view, "#automation-#{definition.id}", "Investigate nightly CI")
    assert has_element?(view, "#automation-#{definition.id}", "generic_ephemeral")
    assert has_element?(view, "#automation-#{definition.id}", "Protected operational policy")
    assert has_element?(view, "#automation-#{definition.id}", "Nightly CI check")

    view
    |> element("button[phx-click=run][phx-value-trigger-id='#{trigger.id}']")
    |> render_click()

    assert has_element?(view, "#automation-history", "queued")
    assert has_element?(view, "#automation-history", "Investigate nightly CI")
  end

  test "creates a disabled generic repository action without code changes", %{conn: conn} do
    repository = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations")

    view
    |> form("#new-automation form", %{
      "automation" => %{
        "repository_id" => to_string(repository.id),
        "key" => "inspect_dependencies",
        "name" => "Inspect dependencies",
        "description" => "Report risky dependencies.",
        "github_access" => "read",
        "agent_kind" => "",
        "queue_lane" => "planning",
        "resource_class" => "light",
        "timeout_seconds" => "1800",
        "operational_policy" => "Do not mutate GitHub.",
        "prompt" => "Inspect dependencies and return a concise report."
      }
    })
    |> render_submit()

    created = Automations.get_definition(repository, "inspect_dependencies")
    refute created.enabled
    assert created.current_version.execution_profile == "generic_ephemeral"
    assert Enum.any?(created.triggers, &(&1.trigger_type == "manual" and not &1.enabled))
    assert has_element?(view, "#automation-#{created.id}", "Inspect dependencies")
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end
end
