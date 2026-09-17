defmodule PtcManagerWeb.AutomationsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.{Automations, Operations}
  alias PtcManager.Automations.{Invocation, Trigger}
  alias PtcManager.Repo
  alias PtcManagerWeb.AutomationsLive

  test "page paths drop blank parameters and keep the repository" do
    assert AutomationsLive.page_path(:index) == "/automations"
    assert AutomationsLive.page_path(:index, repo: nil) == "/automations"
    assert AutomationsLive.page_path(:new, repo: "o/r") == "/automations/new?repo=o%2Fr"
    assert AutomationsLive.page_path(:show, id: 7, repo: "all") == "/automations/7?repo=all"
  end

  test "a paused schedule does not promise a next run" do
    trigger = %Trigger{
      trigger_type: "schedule",
      enabled: false,
      next_run_at: ~U[2026-09-17 00:00:00.000000Z],
      time_zone: "Europe/Stockholm"
    }

    assert AutomationsLive.trigger_detail(trigger) == "Paused · no runs scheduled"

    assert AutomationsLive.trigger_detail(%{trigger | enabled: true}, false) ==
             "Paused · no runs scheduled"

    assert AutomationsLive.trigger_detail(%{trigger | enabled: true}, true) =~ "Next "
  end

  describe "index" do
    test "lists one row per automation with how it runs, the last run, and the next run",
         %{conn: conn} do
      repository = repository_fixture(%{github_name: "ptc_runner"})
      other = repository_fixture()
      nightly = Automations.get_definition(repository, "nightly_ci_investigation")
      digest = Automations.get_definition(repository, "daily_digest")
      other_digest = Automations.get_definition(other, "daily_digest")
      manual = Enum.find(nightly.triggers, &(&1.trigger_type == "manual"))
      {:ok, _invocation} = Automations.run_trigger(manual, "maintainer")

      {:ok, view, html} =
        conn |> authenticated_conn() |> live(~p"/automations?repo=#{key(repository)}")

      assert html =~ "Automations"
      assert has_element?(view, "nav a[href='/automations']", "Automations")
      assert has_element?(view, "#automation-row-#{nightly.id}", "Investigate nightly CI")
      assert has_element?(view, "#automation-row-#{nightly.id}", "built-in")
      assert has_element?(view, "#automation-row-#{nightly.id}", "Run now")
      assert has_element?(view, "#automation-row-#{nightly.id}", "queued")
      assert has_element?(view, "#automation-row-#{nightly.id}", "just now")
      assert has_element?(view, "#automation-row-#{digest.id}", "Paused")
      refute has_element?(view, "#automation-row-#{digest.id}", "02:00 CE")
      assert has_element?(view, "#automation-row-#{digest.id}", "Never")
      refute has_element?(view, "#automation-row-#{other_digest.id}")
      assert has_element?(view, "#latest-runs li", "Investigate nightly CI")

      assert has_element?(
               view,
               "#new-automation-link[href='/automations/new?repo=#{URI.encode_www_form(key(repository))}']"
             )

      view |> element("#automation-switch-#{nightly.id}") |> render_click()
      refute Automations.get_definition(repository, "nightly_ci_investigation").enabled
      assert has_element?(view, "#flash-info", "Investigate nightly CI paused.")
      assert has_element?(view, "#automation-switch-#{nightly.id}[aria-checked=false]")

      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations")
      assert has_element?(view, "#automations-#{repository.id} h2", key(repository))

      assert has_element?(
               view,
               "#automations-#{other.id} #automation-row-#{other_digest.id}",
               "Paused"
             )

      refute has_element?(view, "#latest-runs")
    end
  end

  describe "create" do
    test "derives the key from the name, rejects a duplicate name, and creates a paused automation",
         %{conn: conn} do
      repository = repository_fixture()

      {:ok, view, _html} =
        conn |> authenticated_conn() |> live(~p"/automations/new?repo=#{key(repository)}")

      html =
        view
        |> form("#new-automation-form", automation: %{name: "Inspect Dependencies!"})
        |> render_change()

      assert html =~ ~s(value="inspect_dependencies")

      html =
        view
        |> form("#new-automation-form",
          automation: %{name: "Daily update", description: "Twice", prompt: "x"}
        )
        |> render_submit()

      assert html =~ "is already used by another automation in this repository"
      assert Automations.get_definition(repository, "daily_update") == nil

      view
      |> form("#new-automation-form", automation: %{key: "dependency_audit"})
      |> render_change(%{"_target" => ["automation", "key"]})

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#new-automation-form",
                 automation: %{
                   repository_id: to_string(repository.id),
                   name: "Inspect dependencies",
                   description: "Report risky dependencies.",
                   prompt: "Inspect dependencies read-only and return a concise report.",
                   github_access: "read"
                 }
               )
               |> render_submit()

      created = Automations.get_definition(repository, "dependency_audit")
      refute created.enabled
      assert created.current_version.execution_profile == "generic_ephemeral"
      assert created.current_version.timeout_seconds == 1_800
      assert created.current_version.agent_selector["mode"] == "any"
      assert [%Trigger{trigger_type: "manual", enabled: false}] = created.triggers
      assert to == "/automations/#{created.id}?repo=#{URI.encode_www_form(key(repository))}"

      {:ok, view, _html} = conn |> authenticated_conn() |> live(to)
      assert has_element?(view, "#automation-header", "Inspect dependencies")
      assert has_element?(view, "#automation-header", "custom")
      assert has_element?(view, "#automation-advanced", "dependency_audit")
    end
  end

  describe "detail" do
    test "keeps bare links for other automations but not daily-report prose", %{conn: conn} do
      repository = repository_fixture()

      for {key, auto_links} <- [{"implement_issue", true}, {"daily_digest", false}] do
        definition = Automations.get_definition(repository, key)

        run =
          invocation_fixture(
            definition,
            "succeeded",
            "## Result\n\nhttps://example.org/bare\n\n[Selected](https://github.com/owner/repo/pull/1)"
          )

        {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")
        view |> element("#run-#{run.id} button[phx-click=toggle-run]") |> render_click()

        assert has_element?(view, "#run-result-#{run.id} a[href='https://example.org/bare']") ==
                 auto_links

        assert has_element?(view, "#run-result-#{run.id} a[href$='/pull/1']")
      end
    end

    test "shows the test-capable execution boundary for issue reviews", %{conn: conn} do
      repository = repository_fixture()
      definition = Automations.get_definition(repository, "review_issue")
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      assert has_element?(
               view,
               "#automation-agent",
               "Disposable test-capable investigation worktree"
             )

      assert PtcManagerWeb.AutomationsLive.prompt_preview(definition) =~ "Result protocol:"
    end

    test "saves settings and prompt as a new version and lists only this automation's runs",
         %{conn: conn} do
      repository = repository_fixture(%{github_name: "ptc_runner"})
      definition = Automations.get_definition(repository, "implement_issue")
      nightly = Automations.get_definition(repository, "nightly_ci_investigation")
      mine = invocation_fixture(definition, "succeeded", "## Done\n\nShipped the fix.")
      theirs = invocation_fixture(nightly, "failed", nil)
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      assert has_element?(view, "#automation-header", "Implement issue")
      assert has_element?(view, "#automation-agent", "Writable implementation worktree")
      refute has_element?(view, "#add-schedule")
      assert has_element?(view, "#add-button")
      assert has_element?(view, "#automation-runs #run-#{mine.id}", "succeeded")
      refute has_element?(view, "#automation-runs #run-#{theirs.id}")
      refute has_element?(view, "#run-result-#{mine.id}")

      assert has_element?(
               view,
               "#run-#{mine.id} button[aria-expanded=false][aria-controls='run-result-#{mine.id}']"
             )

      view |> element("#run-#{mine.id} button[phx-click=toggle-run]") |> render_click()
      assert has_element?(view, "#run-result-#{mine.id} h2", "Done")
      assert has_element?(view, "#run-#{mine.id} button[aria-expanded=true]")

      view
      |> form("#automation-settings-form", automation: %{agent_mode: "require"})
      |> render_change()

      view
      |> form("#automation-settings-form",
        automation: %{
          agent_kind: "codex",
          github_access: "brokered_publish",
          timeout_minutes: "90",
          prompt:
            "Use the ptc_runner repository instructions and normal hooks. Explain skipped checks."
        }
      )
      |> render_submit()

      updated = Automations.get_definition(repository, "implement_issue")
      assert updated.current_version.version == 2
      assert updated.current_version.timeout_seconds == 5_400
      assert updated.current_version.prompt =~ "Explain skipped checks"
      assert updated.current_version.execution_profile == "implementation_job"

      assert updated.current_version.agent_selector ==
               %{"mode" => "require", "preferred_kind" => "codex", "required_capabilities" => []}

      view |> element("button[phx-click=show-prompt-preview]") |> render_click()
      preview = "#automation-full-prompt-preview-#{definition.id}"
      assert has_element?(view, preview, "Use the ptc_runner repository instructions")
      refute has_element?(view, preview, "Result protocol:")

      view
      |> element("#automation-prompt-preview button[phx-click=close-prompt-preview]")
      |> render_click()

      refute has_element?(view, "#automation-prompt-preview")

      view |> element("button[phx-click=restore-suggested-prompt]") |> render_click()
      restored = Automations.get_definition(repository, "implement_issue")
      assert restored.current_version.version == 3
      assert restored.current_version.prompt =~ "Fix the issue completely"
      assert has_element?(view, "#automation-versions", "v3 by maintainer")
    end

    test "shows validation errors inline instead of saving", %{conn: conn} do
      repository = repository_fixture()
      definition = Automations.get_definition(repository, "nightly_ci_investigation")
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      html =
        view
        |> form("#automation-settings-form",
          automation: %{name: "Daily update", timeout_minutes: "0"}
        )
        |> render_submit()

      assert html =~ "is already used by another automation in this repository"
      assert html =~ "must be greater than 0"

      assert Automations.get_definition(repository, "nightly_ci_investigation").current_version.version ==
               1
    end

    test "keeps the Advanced section and a trigger editor open across operations re-renders",
         %{conn: conn} do
      repository = repository_fixture()
      definition = Automations.get_definition(repository, "nightly_ci_investigation")
      schedule = Enum.find(definition.triggers, &(&1.trigger_type == "schedule"))
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      refute has_element?(view, "#automation-advanced[open]")
      view |> element("#automation-advanced summary") |> render_click()

      view
      |> element("#trigger-#{schedule.id} button[phx-click=toggle-trigger-editor]")
      |> render_click()

      assert has_element?(view, "#automation-advanced[open]")
      assert has_element?(view, "#trigger-editor-#{schedule.id}")

      send(view.pid, {:operations_changed, :test})
      assert has_element?(view, "#automation-advanced[open]")
      assert has_element?(view, "#trigger-editor-#{schedule.id}")
    end

    test "queues a run and copies the automation to another repository", %{conn: conn} do
      repository = repository_fixture(%{github_name: "ptc_runner"})
      other = repository_fixture()
      definition = Automations.get_definition(repository, "nightly_ci_investigation")
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      view |> element("#run-now") |> render_click()
      assert has_element?(view, "#automation-runs", "queued")
      assert has_element?(view, "#automation-runs", "Manual run · v1")

      view
      |> element("#automation-copy button[phx-value-repository-id='#{other.id}']")
      |> render_click()

      assert %{enabled: false} = Automations.get_definition(other, "nightly_ci_investigation_2")
    end

    test "navigates to the index when the selector chooses another repository", %{conn: conn} do
      repository = repository_fixture()
      other = repository_fixture()
      definition = Automations.get_definition(repository, "daily_digest")

      assert {:error, {:live_redirect, %{to: "/automations?repo=" <> _rest}}} =
               conn
               |> authenticated_conn()
               |> live(~p"/automations/#{definition.id}?repo=#{key(other)}")
    end
  end

  describe "trigger builder" do
    test "adds paused schedules, stores presets, previews next runs, and rejects bad cron",
         %{conn: conn} do
      repository = repository_fixture()
      definition = Automations.get_definition(repository, "nightly_ci_investigation")
      built_in = Enum.find(definition.triggers, &(&1.trigger_type == "schedule"))
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      refute has_element?(view, "#add-button")
      refute has_element?(view, "#trigger-#{built_in.id} button[phx-click=delete-trigger]")

      view |> element("#add-schedule") |> render_click()

      [added] =
        Automations.get_definition!(definition.id).triggers
        |> Enum.reject(&(&1.id in Enum.map(definition.triggers, fn t -> t.id end)))

      refute added.enabled
      assert has_element?(view, "#trigger-editor-#{added.id}")
      assert has_element?(view, "#trigger-#{added.id} button[phx-click=delete-trigger]")

      html =
        view
        |> form("#trigger-form-#{added.id}",
          schedule: %{preset: "daily", time: "03:00", time_zone: "Europe/Stockholm"}
        )
        |> render_change()

      assert html =~ ~s(value="0 3 * * *")
      assert length(Regex.scan(~r/03:00 CE[S]?T \(0[12]:00 UTC\)/, html)) == 3

      view |> form("#trigger-form-#{added.id}", schedule: %{}) |> render_submit()
      saved = Repo.get!(Trigger, added.id)
      assert saved.cron_expression == "0 3 * * *"
      assert saved.time_zone == "Europe/Stockholm"
      assert saved.label == "Every day at 03:00"
      assert saved.next_run_at
      refute has_element?(view, "#trigger-editor-#{added.id}")
      assert has_element?(view, "#trigger-#{added.id}", "Every day at 03:00 · Europe/Stockholm")

      {:ok, _trigger} = Automations.update_trigger(saved, %{cron_expression: "15 9 * * 3"})

      view
      |> element("#trigger-#{added.id} button[phx-click=toggle-trigger-editor]")
      |> render_click()

      assert has_element?(view, "#trigger-form-#{added.id} option[value=weekly][selected]")
      assert has_element?(view, "#trigger-form-#{added.id} option[value='3'][selected]")

      view
      |> form("#trigger-form-#{added.id}", schedule: %{preset: "custom", time_zone: "other"})
      |> render_change()

      html =
        view
        |> form("#trigger-form-#{added.id}",
          schedule: %{cron_expression: "not cron", other_time_zone: "Mars/Olympus"}
        )
        |> render_submit()

      assert html =~ "must be a valid five-field cron expression"
      assert html =~ "is not a known IANA time zone"
      assert Repo.get!(Trigger, added.id).cron_expression == "15 9 * * 3"

      view |> element("#trigger-#{added.id} button[phx-click=delete-trigger]") |> render_click()
      refute Repo.get(Trigger, added.id)
      assert Repo.get!(Trigger, built_in.id)
    end

    test "offers a button on the surface an issue automation targets", %{conn: conn} do
      repository = repository_fixture()
      definition = Automations.get_definition(repository, "implement_issue")
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      view |> element("#add-button") |> render_click()

      [button] =
        Automations.get_definition!(definition.id).triggers
        |> Enum.filter(&(&1.trigger_type == "contextual"))

      assert %{enabled: false, surface: "planning_issue", label: "Implement issue"} = button
      refute has_element?(view, "#add-button")

      view
      |> form("#trigger-form-#{button.id}", trigger: %{label: "Implement now"})
      |> render_submit()

      assert Repo.get!(Trigger, button.id).label == "Implement now"
      assert has_element?(view, "#trigger-#{button.id}", "“Implement now” on Planning issues")

      view |> element("#trigger-switch-#{button.id}") |> render_click()
      assert Repo.get!(Trigger, button.id).enabled
    end
  end

  describe "agent selector" do
    test "offers kinds from online workers and configured profiles", %{conn: conn} do
      {:ok, _online} = worker("online", ["cursor"])
      {:ok, _offline} = worker("offline", ["gemini"])
      repository = repository_fixture()
      definition = Automations.get_definition(repository, "nightly_ci_investigation")
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")

      assert has_element?(view, "#automation_agent_kind[disabled]")

      view
      |> form("#automation-settings-form", automation: %{agent_mode: "prefer"})
      |> render_change()

      refute has_element?(view, "#automation_agent_kind[disabled]")
      assert has_element?(view, "#automation_agent_kind option[value=cursor]", "cursor")
      refute has_element?(view, "#automation_agent_kind option[value=cursor]", "offline")
      assert has_element?(view, "#automation_agent_kind option[value=codex]", "codex (offline)")
      refute has_element?(view, "#automation_agent_kind option[value=gemini]")

      view
      |> form("#automation-settings-form", automation: %{agent_kind: "cursor"})
      |> render_submit()

      version = Automations.get_definition(repository, "nightly_ci_investigation").current_version
      assert version.agent_selector["mode"] == "prefer"
      assert version.agent_selector["preferred_kind"] == "cursor"
      assert has_element?(view, "#automation-header", "v2")
    end
  end

  defp worker(status, kinds) do
    Operations.create_worker(%{
      worker_key: "herdr:#{status}-#{System.unique_integer([:positive])}",
      name: "Herdr #{status}",
      status: status,
      capabilities: %{"herdr" => true, "agent_kinds" => kinds},
      last_heartbeat_at: DateTime.utc_now()
    })
  end

  test "daily quiet runs use the same readable status as Updates", %{conn: conn} do
    repository = repository_fixture()
    :ok = Automations.ensure_defaults(repository)
    definition = Automations.get_definition(repository, "daily_digest")
    run = invocation_fixture(definition, "no_changes", "No changes in the selected window.")
    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/automations/#{definition.id}")
    assert has_element?(view, "#run-#{run.id} span", "Quiet day")
    refute has_element?(view, "#run-#{run.id} span", "no_changes")

    {:ok, index, _} =
      conn |> authenticated_conn() |> live(~p"/automations?repo=#{key(repository)}")

    assert has_element?(index, "#automation-row-#{definition.id}", "Quiet day")
    assert has_element?(index, "#latest-runs", "Quiet day")
    refute has_element?(index, "#latest-runs", "no_changes")
  end

  defp invocation_fixture(definition, state, markdown) do
    %Invocation{}
    |> Invocation.changeset(%{
      repository_id: definition.repository_id,
      automation_definition_version_id: definition.current_version.id,
      trigger_type: "contextual",
      trigger_context: %{},
      state: state,
      result_markdown: markdown,
      requested_by: "maintainer",
      requested_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp key(repository), do: "#{repository.github_owner}/#{repository.github_name}"

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end
end
