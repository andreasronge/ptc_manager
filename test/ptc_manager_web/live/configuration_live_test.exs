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
             "#repository-health-#{repository.id} a[href*='/automations?repo=']",
             "Edit prompts and automations"
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
    assert repository.local_path == "/srv/ptc_manager"
    assert length(PtcManager.Automations.list_definitions(repository)) == 11
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

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
