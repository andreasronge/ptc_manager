defmodule PtcManagerWeb.ConfigurationLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import Plug.Conn

  alias PtcManager.Operations.Repository
  alias PtcManager.{CapacitySettings, Operations, Repo}

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
             "#repository-#{repository.id} a[href='/configuration/repositories/#{repository.id}']",
             "andreasronge/ptc_runner"
           )
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
    assert repository.local_path == "/srv/andreasronge/ptc_manager"
    assert length(PtcManager.Automations.list_definitions(repository)) == 19
    assert has_element?(view, "#repository-#{repository.id}", "Disabled")
    # Its checkout does not exist here, so the badge shows the most urgent check.
    assert has_element?(view, "#repository-#{repository.id}", "attention")
  end

  test "prefills the branch from GitHub unless the maintainer typed one", %{conn: conn} do
    put_tyraorg_repositories()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    view
    |> form("#add-repository form", %{
      "repository" => %{"github_owner" => "tyraorg", "github_name" => "api"}
    })
    |> render_change()

    assert has_element?(view, "input[name='repository[default_branch]'][value='develop']")
    # The re-render keeps the form open.
    assert has_element?(view, "#add-repository[open]")

    # Another repository replaces a prefilled branch, but never a typed one.
    view
    |> form("#add-repository form", %{
      "repository" => %{
        "github_owner" => "tyraorg",
        "github_name" => "web",
        "default_branch" => "develop"
      }
    })
    |> render_change()

    assert has_element?(view, "input[name='repository[default_branch]'][value='main']")

    view
    |> form("#add-repository form", %{
      "repository" => %{
        "github_owner" => "tyraorg",
        "github_name" => "api",
        "default_branch" => "feature/ska"
      }
    })
    |> render_change()

    assert has_element?(view, "input[name='repository[default_branch]'][value='feature/ska']")
  end

  test "a failed lookup does not turn a prefilled branch into a typed one", %{conn: conn} do
    put_tyraorg_repositories()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    for {name, branch} <- [{"api", ""}, {"wbe", "develop"}, {"web", "develop"}] do
      view
      |> form("#add-repository form", %{
        "repository" => %{
          "github_owner" => "tyraorg",
          "github_name" => name,
          "default_branch" => branch
        }
      })
      |> render_change()
    end

    assert has_element?(view, "input[name='repository[default_branch]'][value='main']")
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
    assert repository.local_path == "/srv/andreasronge/ptc-fs-mcp"
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

    assert repository.local_path == "/srv/andreasronge/string-keys"
    assert repository.default_branch == "trunk"
    refute repository.enabled
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

  defp put_tyraorg_repositories do
    previous = Application.get_env(:ptc_manager, :test_github_repositories, :all)
    on_exit(fn -> Application.put_env(:ptc_manager, :test_github_repositories, previous) end)

    Application.put_env(:ptc_manager, :test_github_repositories, %{
      {"tyraorg", "api"} =>
        {:ok, %{"nameWithOwner" => "tyraorg/api", "defaultBranchRef" => %{"name" => "develop"}}},
      {"tyraorg", "web"} =>
        {:ok, %{"nameWithOwner" => "tyraorg/web", "defaultBranchRef" => %{"name" => "main"}}}
    })
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end
end
