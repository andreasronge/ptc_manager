defmodule PtcManagerWeb.ConfigurationLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import Plug.Conn

  alias PtcManager.Operations.Repository
  alias PtcManager.{Operations, PromptConfiguration, Repo}

  test "lists every button prompt and saves and resets instructions", %{conn: conn} do
    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/configuration")

    assert html =~ "Agent prompt instructions"
    assert has_element?(view, "nav", "Configuration")
    assert has_element?(view, "#prompt-private_issue_analysis", "Investigate privately")
    assert has_element?(view, "#prompt-implement_issue", "Approve and start")
    assert has_element?(view, "#prompt-prepare_issue", "Button: Prepare issue")
    assert has_element?(view, "#prompt-review_issue", "Button: Review issue")
    assert has_element?(view, "#prompt-daily_digest", "Button: Generate daily update")
    assert has_element?(view, "#prompt-resolve_issue_decision", "Button: Apply decision")
    assert has_element?(view, "#prompt-repair_pr", "Button: Fix")
    assert has_element?(view, "#prompt-repair_and_merge_pr", "Button: Fix and merge")
    assert has_element?(view, "#prompt-implement_issue", "Agent retrospective")

    view
    |> form("#prompt-repair_and_merge_pr form", %{
      "action-key" => "repair_and_merge_pr",
      "customization" => %{
        "instructions" => "Mention the merge commit SHA in the final evidence."
      }
    })
    |> render_submit()

    assert PromptConfiguration.instructions("repair_and_merge_pr") ==
             "Mention the merge commit SHA in the final evidence."

    assert has_element?(view, "#prompt-repair_and_merge_pr", "Customized")

    view
    |> element("#prompt-repair_and_merge_pr button[phx-click=show-prompt-preview]")
    |> render_click()

    assert has_element?(view, "#prompt-preview", "Example composed prompt")
    assert has_element?(view, "#prompt-preview", "Protected instructions")
    assert has_element?(view, "#prompt-preview", "andreasronge/example_repository")

    assert has_element?(
             view,
             "#full-prompt-preview-repair_and_merge_pr",
             "Mention the merge commit SHA in the final evidence."
           )

    assert has_element?(
             view,
             "#full-prompt-preview-repair_and_merge_pr",
             "explicit maintainer authorization to merge only pull request #456"
           )

    send(view.pid, {:operations_changed, Repository})
    assert has_element?(view, "#prompt-preview", "Example composed prompt")

    view
    |> element("#prompt-preview button[phx-click=close-prompt-preview]")
    |> render_click()

    refute has_element?(view, "#prompt-preview")

    view
    |> element("#prompt-repair_and_merge_pr button[phx-click=reset-prompt]")
    |> render_click()

    assert is_nil(PromptConfiguration.instructions("repair_and_merge_pr"))
    assert has_element?(view, "#prompt-repair_and_merge_pr", "Default")
  end

  test "registers another repository disabled with its own automation defaults", %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "ptc-manager-onboarding-checkout")
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/configuration")

    view
    |> form("#add-repository form", %{
      "repository" => %{
        "github_owner" => "andreasronge",
        "github_name" => "ptc_manager",
        "default_branch" => "main",
        "local_path" => path
      }
    })
    |> render_submit()

    repository =
      Repo.get_by!(Repository, github_owner: "andreasronge", github_name: "ptc_manager")

    refute repository.enabled
    assert length(PtcManager.Automations.list_definitions(repository)) == 12
    assert has_element?(view, "#repository-health-#{repository.id}", "Disabled")
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
