defmodule PtcManagerWeb.ConfigurationLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import Plug.Conn

  alias PtcManager.Operations.{AuditEvent, Repository}
  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.{CapacitySettings, Operations, Repo}

  test "toggles automatic implementation for only the selected repository", %{conn: conn} do
    repository = repository_fixture()
    other = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")
    assert has_element?(view, "#auto-fix-#{repository.id}", "Enable automatic implementation")
    view |> element("#auto-fix-#{repository.id}") |> render_click()
    assert Repo.get!(Repository, repository.id).auto_fix_issues
    refute Repo.get!(Repository, other.id).auto_fix_issues
    assert has_element?(view, "#auto-fix-#{repository.id}", "Disable automatic implementation")
    view |> element("#auto-fix-#{repository.id}") |> render_click()
    refute Repo.get!(Repository, repository.id).auto_fix_issues
  end

  test "edits the automatic implementation daily limit per repository", %{conn: conn} do
    repository = repository_fixture()
    other = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert view
           |> form("#auto-fix-daily-limit-#{repository.id}", %{auto_fix: %{daily_limit: "12"}})
           |> render_submit() =~ "Automatic implementation daily limit saved."

    assert Repo.get!(Repository, repository.id).auto_fix_daily_limit == 12
    assert Repo.get!(Repository, other.id).auto_fix_daily_limit == 5

    for params <- [
          %{"auto_fix" => %{"repository_id" => "#{repository.id}", "daily_limit" => "0"}},
          %{"auto_fix" => %{"repository_id" => "#{repository.id}", "daily_limit" => "x"}},
          %{"auto_fix" => %{"repository_id" => "invalid", "daily_limit" => "3"}},
          %{}
        ] do
      assert render_submit(view, "set-auto-fix-daily-limit", params) =~
               "The daily limit must be a whole number from 1 to 50."
    end

    assert Repo.get!(Repository, repository.id).auto_fix_daily_limit == 12
  end

  test "malformed auto-fix events leave the configuration view running", %{conn: conn} do
    {:ok, view, _} = conn |> authenticated_conn() |> live(~p"/configuration")

    for params <- [
          %{"id" => "invalid", "enabled" => "true"},
          %{"id" => "1", "enabled" => "invalid"},
          %{},
          %{"id" => 1, "enabled" => "true"}
        ] do
      assert render_click(view, "set-auto-fix", params) =~
               "Could not save automatic implementation setting."
    end

    assert Process.alive?(view.pid)
  end

  test "edits independent light, heavy, and expensive-operation limits", %{conn: conn} do
    original = CapacitySettings.current()

    on_exit(fn ->
      CapacitySettings.update(%{
        light_agent_capacity: original.light_agent_capacity,
        heavy_agent_capacity: original.heavy_agent_capacity,
        operation_capacity: original.operation_capacity
      })
    end)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(view, "#agent-capacity", "Light agents")
    assert has_element?(view, "#agent-capacity", "Expensive operations")
    assert has_element?(view, "#agent-capacity", "merge → repair → new implementation")

    view
    |> form("#agent-capacity form", %{
      "capacity" => %{
        "light_agent_capacity" => "3",
        "heavy_agent_capacity" => "2",
        "operation_capacity" => "1"
      }
    })
    |> render_submit()

    assert CapacitySettings.current().light_agent_capacity == 3
    assert CapacitySettings.current().heavy_agent_capacity == 2
    assert CapacitySettings.current().operation_capacity == 1
    assert Application.get_env(:ptc_manager, :light_agent_capacity) == 3
    assert Application.get_env(:ptc_manager, :heavy_agent_capacity) == 2
    assert Application.get_env(:ptc_manager, :operation_capacity) == 1
    assert render(view) =~ "Worker capacity updated"
  end

  test "routes repository-specific prompt editing to versioned automations", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreasronge", github_name: "ptc_runner"})
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert html =~ "Repository configuration"
    assert has_element?(view, "nav", "Configuration")
    assert has_element?(view, "aside", "Prompts are repository-specific and fully editable")

    assert has_element?(
             view,
             "#repository-health-#{repository.id} a[href*='/automations?repo=']",
             "Edit prompts and automations"
           )
  end

  test "adds, replaces, and deletes write-only implementation-agent variables", %{conn: conn} do
    repository = repository_fixture()
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/configuration")

    refute html =~ "browser-secret"

    view
    |> form("#agent-environment-#{repository.id} form", %{
      "repository-id" => repository.id,
      "variable" => %{"name" => "OPENROUTER_API_KEY", "secret" => "browser-secret"}
    })
    |> render_submit()

    [variable] = AgentEnvironmentVariables.list(repository.id)
    assert variable.value == "browser-secret"
    assert has_element?(view, "#agent-environment-variable-#{variable.id}", "OPENROUTER_API_KEY")
    refute render(view) =~ "browser-secret"

    view
    |> form("#agent-environment-#{repository.id} form", %{
      "repository-id" => repository.id,
      "variable" => %{"name" => "OPENROUTER_API_KEY", "secret" => "rotated-secret"}
    })
    |> render_submit()

    assert [%{id: id, value: "rotated-secret"}] = AgentEnvironmentVariables.list(repository.id)
    assert id == variable.id
    refute render(view) =~ "rotated-secret"

    view
    |> element("#agent-environment-variable-#{variable.id} button", "Delete")
    |> render_click()

    assert AgentEnvironmentVariables.list(repository.id) == []
  end

  test "registers another repository disabled with its own automation defaults", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    refute has_element?(view, "#add-repository input[name='repository[local_path]']")
    assert has_element?(view, "#add-repository button", "Add repository")

    view
    |> form("#add-repository form", %{
      "repository" => %{
        "github_owner" => "andreasronge",
        "github_name" => "ptc_manager",
        "default_branch" => "main"
      }
    })
    |> render_submit()

    repository =
      Repo.get_by!(Repository, github_owner: "andreasronge", github_name: "ptc_manager")

    refute repository.enabled
    assert repository.local_path == "/srv/ptc_manager"
    assert length(PtcManager.Automations.list_definitions(repository)) == 19
    assert has_element?(view, "#repository-health-#{repository.id}", "Disabled")
    assert has_element?(view, "#repository-health-#{repository.id}", "/srv/ptc_manager")
  end

  test "keeps repository input and explains GitHub validation failures", %{conn: conn} do
    previous = Application.get_env(:ptc_manager, :test_github_repositories, :all)
    on_exit(fn -> Application.put_env(:ptc_manager, :test_github_repositories, previous) end)

    Application.put_env(:ptc_manager, :test_github_repositories, %{
      {"andreasronge", "offline"} => {:error, {:github_transport_error, :timeout}}
    })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    html =
      view
      |> form("#add-repository form",
        repository: %{github_owner: "andreasronge", github_name: "typo", default_branch: "trunk"}
      )
      |> render_submit()

    assert html =~ "could not find that exact owner/name"
    assert has_element?(view, "input[name='repository[github_name]'][value='typo']")
    refute Repo.get_by(Repository, github_name: "typo")

    html =
      view
      |> form("#add-repository form",
        repository: %{
          github_owner: "andreasronge",
          github_name: "offline",
          default_branch: "main"
        }
      )
      |> render_submit()

    assert html =~ "GitHub access is currently unavailable"
    refute Repo.get_by(Repository, github_name: "offline")
  end

  # Onboarding derives a checkout path it cannot create, so the page has to offer
  # the host the work and say plainly when the host cannot take it.
  test "preparing checkouts reports when the host has no provisioning unit", %{conn: conn} do
    previous = Application.get_env(:ptc_manager, :provision_systemctl_command)
    Application.delete_env(:ptc_manager, :provision_systemctl_command)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ptc_manager, :provision_systemctl_command)
        value -> Application.put_env(:ptc_manager, :provision_systemctl_command, value)
      end
    end)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    html = view |> element("#prepare-repositories") |> render_click()

    assert html =~ "no repository provisioning unit installed"
  end

  # Onboarding registers a repository disabled so a maintainer can verify it
  # first, and synchronization only covers enabled repositories. Without a way to
  # enable one, a newly added repository could never be used and its GitHub check
  # could never go green.
  test "a maintainer can enable and disable a repository", %{conn: conn} do
    repository = repository_fixture(%{github_name: "toggle-me", enabled: false})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(view, "#toggle-repository-#{repository.id}", "Enable")

    assert has_element?(
             view,
             "#repository-health-#{repository.id}",
             "turns green once it is enabled"
           )

    html = view |> element("#toggle-repository-#{repository.id}") |> render_click()

    assert html =~ "is enabled"
    assert Repo.get!(Repository, repository.id).enabled
    assert has_element?(view, "#toggle-repository-#{repository.id}", "Disable")

    assert Repo.get_by!(AuditEvent, action: "repository.enabled", target_id: repository.id)

    html = view |> element("#toggle-repository-#{repository.id}") |> render_click()

    assert html =~ "is disabled"
    refute Repo.get!(Repository, repository.id).enabled
  end

  test "rejects names that cannot produce a safe checkout component without persistence" do
    before_count = Repo.aggregate(Repository, :count)

    assert {:error, :unsafe_repository_name} =
             Operations.onboard_repository(%{
               github_owner: "andreasronge",
               github_name: "../escape",
               default_branch: "main",
               enabled: false
             })

    assert Repo.aggregate(Repository, :count) == before_count
  end

  # A maintainer pastes an owner and a repository name, and a paste routinely
  # carries a leading or trailing space. Rejecting that with a message about
  # /srv path components says nothing about what is actually wrong.
  test "accepts an owner and name pasted with surrounding whitespace" do
    assert {:ok, repository} =
             Operations.onboard_repository(%{
               github_owner: " andreasronge ",
               github_name: "ptc-fs-mcp\n",
               default_branch: " main "
             })

    assert repository.github_owner == "andreasronge"
    assert repository.github_name == "ptc-fs-mcp"
    assert repository.default_branch == "main"
    assert repository.local_path == "/srv/ptc-fs-mcp"
  end

  test "normalizes string-keyed onboarding attributes and keeps repositories disabled" do
    assert {:ok, repository} =
             Operations.onboard_repository(%{
               "github_owner" => "andreasronge",
               "github_name" => "string-keys",
               "default_branch" => "trunk",
               "enabled" => true,
               "local_path" => "/tmp/not-used"
             })

    assert repository.local_path == "/srv/string-keys"
    assert repository.default_branch == "trunk"
    refute repository.enabled
  end

  test "requires confirmation and removes only internal records", %{conn: conn} do
    checkout = Path.join(System.tmp_dir!(), "ptc-retired-#{System.unique_integer([:positive])}")

    repository =
      repository_fixture(%{
        github_owner: "andreasronge",
        github_name: "retired",
        local_path: checkout
      })

    checkout = repository.local_path
    File.mkdir_p!(checkout)
    marker = Path.join(checkout, "keep-me")
    File.write!(marker, "external")
    on_exit(fn -> File.rm_rf!(checkout) end)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    view
    |> element("#repository-health-#{repository.id} button", "Remove repository")
    |> render_click()

    assert has_element?(view, "#remove-repository-dialog", "andreasronge/retired")
    assert Repo.get(Repository, repository.id)

    view |> element("#remove-repository-dialog button", "Cancel") |> render_click()
    assert Repo.get(Repository, repository.id)

    view
    |> element("#repository-health-#{repository.id} button", "Remove repository")
    |> render_click()

    view |> element("#remove-repository-dialog button", "Remove repository") |> render_click()
    refute Repo.get(Repository, repository.id)
    assert File.read!(marker) == "external"
  end

  test "refuses confirmed removal while managed work is active", %{conn: conn} do
    repository = repository_fixture(%{github_name: "busy-repository"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _action} =
             Operations.enqueue_agent_action(%{
               repository_id: repository.id,
               action_key: "prepare_issue",
               target_type: "repository",
               target_id: repository.id,
               target_label: "Busy repository",
               prompt_version: 1,
               prompt: "Inspect",
               actor: "maintainer",
               requested_at: now
             })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    view
    |> element("#repository-health-#{repository.id} button", "Remove repository")
    |> render_click()

    html =
      view
      |> element("#remove-repository-dialog button", "Remove repository")
      |> render_click()

    assert html =~ "has active managed work"
    assert Repo.get(Repository, repository.id)
  end

  test "refuses removal while a retained external workspace awaits cleanup" do
    repository = repository_fixture(%{github_name: "retained-workspace"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, action} =
      Operations.enqueue_agent_action(%{
        repository_id: repository.id,
        action_key: "repair_pr",
        target_type: "pull_request",
        target_id: 42,
        target_label: "Retained workspace",
        prompt_version: 1,
        prompt: "Repair",
        actor: "maintainer",
        requested_at: now
      })

    action
    |> PtcManager.Operations.AgentAction.changeset(%{state: "done", ended_at: now})
    |> Repo.update!()

    worker = worker_fixture(%{worker_key: "herdr:retained-removal"})

    assert {:ok, _run} =
             Operations.create_agent_run(%{
               worker_id: worker.id,
               agent_action_id: action.id,
               role: "implementer",
               state: "done",
               status_text: "Awaiting external workspace cleanup.",
               started_at: now,
               last_heartbeat_at: now,
               ended_at: now,
               herdr_workspace: "retained-external-workspace"
             })

    assert {:error, :active_work} = Operations.remove_repository(repository.id)
    assert Repo.get(Repository, repository.id)
  end

  test "allows removal after a generic action closed its workspace" do
    repository = repository_fixture(%{github_name: "closed-generic-workspace"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, action} =
      Operations.enqueue_agent_action(%{
        repository_id: repository.id,
        action_key: "prepare_issue",
        target_type: "repository",
        target_id: repository.id,
        target_label: "Completed generic action",
        prompt_version: 1,
        prompt: "Inspect",
        actor: "maintainer",
        requested_at: now
      })

    action
    |> PtcManager.Operations.AgentAction.changeset(%{state: "done", ended_at: now})
    |> Repo.update!()

    worker = worker_fixture(%{worker_key: "herdr:closed-generic-removal"})

    assert {:ok, _run} =
             Operations.create_agent_run(%{
               worker_id: worker.id,
               agent_action_id: action.id,
               role: "manager",
               state: "done",
               status_text: "Workspace closed.",
               started_at: now,
               last_heartbeat_at: now,
               ended_at: now,
               herdr_workspace: "historical-generic-workspace"
             })

    assert {:ok, _repository} = Operations.remove_repository(repository.id)
    refute Repo.get(Repository, repository.id)
  end

  test "clears a confirmation dialog after peer removal", %{conn: conn} do
    repository = repository_fixture(%{github_name: "peer-removed"})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    view
    |> element("#repository-health-#{repository.id} button", "Remove repository")
    |> render_click()

    assert has_element?(view, "#remove-repository-dialog")
    assert {:ok, _repository} = Operations.remove_repository(repository.id)
    refute render(view) =~ "remove-repository-dialog"
  end

  test "shows repository checkout, GitHub, and publication-gate health", %{conn: conn} do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-configuration-health-#{System.unique_integer([:positive, :monotonic])}"
      )

    ready_path = Path.join(root, "ready")
    File.mkdir_p!(ready_path)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(ready_path, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: mix deps.get
        timeout_minutes: 10
      verification:
        before_publish: mix precommit
        timeout_minutes: 30
      """
    )

    git!(ready_path, ["init", "-b", "main"])
    git!(ready_path, ["config", "user.email", "test@example.com"])
    git!(ready_path, ["config", "user.name", "PtcManager Test"])
    git!(ready_path, ["add", ".ptc-manager.yml"])
    git!(ready_path, ["commit", "-m", "add publication contract"])

    File.write!(Path.join(ready_path, ".ptc-manager.yml"), "version: 99\n")

    ready =
      repository_fixture(%{
        github_owner: "andreas",
        github_name: "ready-repository",
        local_path: ready_path,
        sync_status: "ok",
        last_synced_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    setup_only_path = Path.join(root, "setup-only")
    File.mkdir_p!(setup_only_path)

    File.write!(
      Path.join(setup_only_path, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: ./scripts/ptc/bootstrap
        timeout_minutes: 10
      """
    )

    git!(setup_only_path, ["init", "-b", "main"])
    git!(setup_only_path, ["config", "user.email", "test@example.com"])
    git!(setup_only_path, ["config", "user.name", "PtcManager Test"])
    git!(setup_only_path, ["add", ".ptc-manager.yml"])
    git!(setup_only_path, ["commit", "-m", "add setup contract"])

    setup_only =
      repository_fixture(%{
        github_owner: "andreas",
        github_name: "agent-published-repository",
        local_path: setup_only_path
      })

    missing =
      repository_fixture(%{
        github_owner: "andreas",
        github_name: "missing-repository",
        local_path: Path.join(root, "missing")
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(view, "#repository-health-#{ready.id}", "Checkout verified")
    assert has_element?(view, "#repository-health-#{ready.id}", "GitHub read access verified")

    assert has_element?(
             view,
             "#repository-health-#{ready.id}",
             "Optional broker verification ready"
           )

    assert has_element?(view, "#repository-health-#{ready.id}", "mix precommit")

    assert has_element?(view, "#repository-health-#{setup_only.id}", "Repository setup ready")

    assert has_element?(
             view,
             "#repository-health-#{setup_only.id}",
             "broker verification is not configured"
           )

    assert has_element?(
             view,
             "#repository-health-#{missing.id}",
             "Checkout needs attention"
           )

    assert has_element?(view, "#repository-health-#{missing.id}", "Configure an existing")

    assert has_element?(
             view,
             "#repository-health-#{missing.id}",
             "Repository contract not checked"
           )

    syncing =
      ready
      |> Repository.changeset(%{sync_status: "syncing"})
      |> Repo.update!()

    Operations.notify_changed(PtcManager.GitHub.Sync)

    assert has_element?(view, "#repository-health-#{syncing.id}", "GitHub read access syncing")

    assert has_element?(
             view,
             "#repository-health-#{syncing.id}",
             "Refreshing repository data now"
           )
  end

  test "does not accept an untracked publication contract", %{conn: conn} do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-untracked-contract-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(root, "README.md"), "fixture\n")
    git!(root, ["add", "README.md"])
    git!(root, ["commit", "-m", "initial commit"])

    File.write!(
      Path.join(root, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: mix deps.get
        timeout_minutes: 10
      verification:
        before_publish: mix precommit
        timeout_minutes: 30
      """
    )

    repository = repository_fixture(%{github_name: "untracked-contract", local_path: root})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(
             view,
             "#repository-health-#{repository.id}",
             "Repository contract needs attention"
           )

    assert has_element?(view, "#repository-health-#{repository.id}", "Add .ptc-manager.yml")
  end

  test "checks the publication contract on the configured default branch", %{conn: conn} do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-default-branch-contract-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(root, "README.md"), "fixture\n")
    git!(root, ["add", "README.md"])
    git!(root, ["commit", "-m", "initial commit"])
    git!(root, ["checkout", "-b", "feature/contract"])

    File.write!(
      Path.join(root, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: mix deps.get
        timeout_minutes: 10
      verification:
        before_publish: mix precommit
        timeout_minutes: 30
      """
    )

    git!(root, ["add", ".ptc-manager.yml"])
    git!(root, ["commit", "-m", "add contract on feature only"])

    repository = repository_fixture(%{github_name: "feature-contract", local_path: root})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(
             view,
             "#repository-health-#{repository.id}",
             "Repository contract needs attention"
           )

    assert has_element?(view, "#repository-health-#{repository.id}", "Add .ptc-manager.yml")
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

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/configuration")

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

    {:ok, _view, html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert html =~ "New jobs use agent publication · authenticated worker creates the PR"
    refute html =~ "without GitHub writes"
  end

  test "shows read-only GitHub synchronization state per repository", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "integrations"})

    repository
    |> Repository.changeset(%{sync_status: "ok", last_synced_at: DateTime.utc_now()})
    |> Repo.update!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(view, "#integrations", "andreas/integrations")
    assert has_element?(view, "#integrations", "connected")
    assert has_element?(view, "#integrations", "Last complete sync:")
    assert has_element?(view, "#integrations", "GitHub identity unknown until the next sync")

    repository
    |> Repository.changeset(%{github_viewer_login: "andreasronge"})
    |> Repo.update!()

    {:ok, identified, _html} = conn |> authenticated_conn() |> live(~p"/configuration")
    assert has_element?(identified, "#integrations", "Reads GitHub as @andreasronge")
  end

  test "configures the maintainer's own triage labels per repository", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "labelled"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    view
    |> form("#add-maintainer-label-#{repository.id}", %{
      "label" => %{
        "repository_id" => Integer.to_string(repository.id),
        "name" => "wait",
        "role" => "park"
      }
    })
    |> render_submit()

    assert render(view) =~ "It must already exist on GitHub"
    assert has_element?(view, "#maintainer-labels-#{repository.id}", "wait")

    assert Repo.get!(Repository, repository.id).maintainer_labels == %{
             "labels" => [%{"name" => "wait", "role" => "park"}]
           }

    for reserved <- ["ptc:ready", "PTC:ready", "Ptc:Blocked"] do
      view
      |> form("#add-maintainer-label-#{repository.id}", %{
        "label" => %{
          "repository_id" => Integer.to_string(repository.id),
          "name" => reserved,
          "role" => "badge"
        }
      })
      |> render_submit()

      assert render(view) =~ "belong to PtcManager"
    end

    # GitHub label names are case-insensitive, so neither is a second label.
    view
    |> form("#add-maintainer-label-#{repository.id}", %{
      "label" => %{
        "repository_id" => Integer.to_string(repository.id),
        "name" => "WAIT",
        "role" => "badge"
      }
    })
    |> render_submit()

    assert render(view) =~ "already configured"

    assert Repo.get!(Repository, repository.id).maintainer_labels == %{
             "labels" => [%{"name" => "wait", "role" => "park"}]
           }

    view
    |> element("#maintainer-labels-#{repository.id} button[phx-value-name='wait']")
    |> render_click()

    assert Repo.get!(Repository, repository.id).maintainer_labels == %{"labels" => []}
  end

  test "names the GitHub labels a repository is still missing", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "unlabelled"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(
             view,
             "#repository-health-#{repository.id}",
             "GitHub labels not checked"
           )

    repository
    |> Repository.changeset(%{
      github_label_names: %{"names" => ["PTC:Ready", "ptc:blocked", "bug"]},
      github_labels_checked_at: DateTime.utc_now(),
      maintainer_labels: %{"labels" => [%{"name" => "wait", "role" => "park"}]}
    })
    |> Repo.update!()

    {:ok, partial, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    detail = render(view_health(partial, repository))
    assert detail =~ "GitHub labels missing"
    assert detail =~ "ptc:needs-decision"
    assert detail =~ "ptc:follow-up"
    assert detail =~ "wait"
    # Casing is GitHub's, not ours: PTC:Ready already covers ptc:ready.
    refute detail =~ "ptc:ready,"

    repository
    |> Repository.changeset(%{
      github_label_names: %{
        "names" => ["ptc:ready", "ptc:blocked", "ptc:needs-decision", "ptc:follow-up", "wait"]
      }
    })
    |> Repo.update!()

    {:ok, complete, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert has_element?(
             complete,
             "#repository-health-#{repository.id}",
             "GitHub labels present"
           )
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end

  defp view_health(view, repository) do
    element(view, "#repository-health-#{repository.id}")
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
