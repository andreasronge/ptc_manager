defmodule PtcManagerWeb.AutomationsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.{Automations, Operations}

  test "shows definitions, complete configuration, schedules, and run history", %{conn: conn} do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")
    trigger = Enum.find(definition.triggers, &(&1.trigger_type == "manual"))

    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/automations")

    assert html =~ "Automations"
    assert has_element?(view, "nav", "Automations")
    assert has_element?(view, "#automation-#{definition.id}", "Investigate nightly CI")
    assert has_element?(view, "#automation-#{definition.id}", "generic_ephemeral")

    editor = "#automation-editor-#{definition.id}"
    refute has_element?(view, "#{editor}[open]")

    view |> element("#{editor} summary") |> render_click()
    assert has_element?(view, "#{editor}[open]")

    send(view.pid, {:operations_changed, Operations})
    assert has_element?(view, "#{editor}[open]")

    assert has_element?(
             view,
             "#automation-#{definition.id}",
             "complete user-owned instruction"
           )

    view
    |> element("#automation-#{definition.id} button[phx-click=show-prompt-preview]")
    |> render_click()

    assert has_element?(view, "#automation-prompt-preview", "Your complete prompt")

    assert has_element?(
             view,
             "#automation-full-prompt-preview-#{definition.id}",
             "Inspect the latest completed nightly GitHub Actions workflow"
           )

    assert has_element?(
             view,
             "#automation-full-prompt-preview-#{definition.id}",
             "Result protocol: read <generated-result-path>.schema.json"
           )

    view
    |> element("#automation-prompt-preview button[phx-click=close-prompt-preview]")
    |> render_click()

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
        "prompt" => "Inspect dependencies read-only and return a concise report."
      }
    })
    |> render_submit()

    created = Automations.get_definition(repository, "inspect_dependencies")
    refute created.enabled
    assert created.current_version.execution_profile == "generic_ephemeral"
    assert Enum.any?(created.triggers, &(&1.trigger_type == "manual" and not &1.enabled))
    assert has_element?(view, "#automation-#{created.id}", "Inspect dependencies")
  end

  test "saves the complete editable prompt as a new version", %{conn: conn} do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "implement_issue")
    current = definition.current_version
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations")

    view
    |> form("#automation-#{definition.id} form[phx-submit=save-definition]", %{
      "definition_id" => to_string(definition.id),
      "automation" => %{
        "name" => definition.name,
        "description" => definition.description,
        "enabled" => "true",
        "execution_profile" => current.execution_profile,
        "agent_mode" => "any",
        "agent_kind" => "",
        "github_access" => current.github_access,
        "queue_lane" => current.queue_lane,
        "resource_class" => current.resource_class,
        "timeout_seconds" => to_string(current.timeout_seconds),
        "prompt" =>
          "Use the ptc_runner repository instructions and normal hooks. Implement the selected issue and explain skipped checks."
      }
    })
    |> render_submit()

    updated = Automations.get_definition(repository, "implement_issue")
    assert updated.current_version.version == 2
    assert updated.current_version.prompt =~ "ptc_runner repository instructions"
    assert updated.current_version.prompt =~ "explain skipped checks"

    view
    |> element("#automation-#{definition.id} button[phx-click=show-prompt-preview]")
    |> render_click()

    assert has_element?(
             view,
             "#automation-full-prompt-preview-#{definition.id}",
             "Use the ptc_runner repository instructions and normal hooks."
           )

    assert has_element?(
             view,
             "#automation-full-prompt-preview-#{definition.id}",
             "Implement the selected issue and explain skipped checks."
           )

    refute has_element?(
             view,
             "#automation-full-prompt-preview-#{definition.id}",
             "Result protocol:"
           )

    view
    |> element("#automation-#{definition.id} button[phx-click=restore-suggested-prompt]")
    |> render_click()

    restored = Automations.get_definition(repository, "implement_issue")
    assert restored.current_version.version == 3
    assert restored.current_version.prompt =~ "For #{repository.github_owner}/ptc_runner"
    assert restored.current_version.prompt =~ "Fix the issue completely"
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end
end
