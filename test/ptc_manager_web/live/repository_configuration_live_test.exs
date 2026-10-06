defmodule PtcManagerWeb.RepositoryConfigurationLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import Plug.Conn

  alias PtcManager.Operations.{AuditEvent, Repository}
  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.{Operations, Repo}

  test "toggles automatic implementation for only the selected repository", %{conn: conn} do
    repository = repository_fixture()
    other = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))
    assert has_element?(view, "#auto-fix-toggle", "Enable automatic implementation")
    view |> element("#auto-fix-toggle") |> render_click()
    assert Repo.get!(Repository, repository.id).auto_fix_issues
    refute Repo.get!(Repository, other.id).auto_fix_issues
    assert has_element?(view, "#auto-fix-toggle", "Disable automatic implementation")
    view |> element("#auto-fix-toggle") |> render_click()
    refute Repo.get!(Repository, repository.id).auto_fix_issues
  end

  test "edits the automatic implementation daily limit per repository", %{conn: conn} do
    repository = repository_fixture()
    other = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert view
           |> form("#auto-fix-daily-limit", %{auto_fix: %{daily_limit: "12"}})
           |> render_submit() =~ "Automatic implementation daily limit saved."

    assert Repo.get!(Repository, repository.id).auto_fix_daily_limit == 12
    assert Repo.get!(Repository, other.id).auto_fix_daily_limit == 5

    for params <- [
          %{"auto_fix" => %{"daily_limit" => "0"}},
          %{"auto_fix" => %{"daily_limit" => "x"}},
          %{}
        ] do
      assert render_submit(view, "set-auto-fix-daily-limit", params) =~
               "The daily limit must be a whole number from 1 to 50."
    end

    assert Repo.get!(Repository, repository.id).auto_fix_daily_limit == 12
  end

  test "malformed auto-fix events leave the configuration view running", %{conn: conn} do
    repository = repository_fixture()
    {:ok, view, _} = conn |> authenticated_conn() |> live(repository_path(repository))

    for params <- [%{"enabled" => "invalid"}, %{}, %{"enabled" => true}] do
      assert render_click(view, "set-auto-fix", params) =~
               "Could not save automatic implementation setting."
    end

    assert Process.alive?(view.pid)
  end

  test "adds, replaces, and deletes write-only implementation-agent variables", %{conn: conn} do
    repository = repository_fixture()
    {:ok, view, html} = conn |> authenticated_conn() |> live(repository_path(repository))

    refute html =~ "browser-secret"

    view
    |> form("#agent-environment form", %{
      "variable" => %{"name" => "OPENROUTER_API_KEY", "secret" => "browser-secret"}
    })
    |> render_submit()

    [variable] = AgentEnvironmentVariables.list(repository.id)
    assert variable.value == "browser-secret"
    assert has_element?(view, "#agent-environment-variable-#{variable.id}", "OPENROUTER_API_KEY")
    refute render(view) =~ "browser-secret"

    view
    |> form("#agent-environment form", %{
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

  # Onboarding registers a repository disabled so a maintainer can verify it
  # first, and synchronization only covers enabled repositories. Without a way to
  # enable one, a newly added repository could never be used and its GitHub check
  # could never go green.
  test "a maintainer can enable and disable a repository", %{conn: conn} do
    repository = repository_fixture(%{github_name: "toggle-me", enabled: false})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert has_element?(view, "#toggle-repository", "Enable")

    assert has_element?(
             view,
             "#repository-health",
             "turns green once it is enabled"
           )

    html = view |> element("#toggle-repository") |> render_click()

    assert html =~ "is enabled"
    assert Repo.get!(Repository, repository.id).enabled
    assert has_element?(view, "#toggle-repository", "Disable")

    assert Repo.get_by!(AuditEvent, action: "repository.enabled", target_id: repository.id)

    html = view |> element("#toggle-repository") |> render_click()

    assert html =~ "is disabled"
    refute Repo.get!(Repository, repository.id).enabled
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

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    view
    |> element("#remove-repository button", "Remove repository")
    |> render_click()

    assert has_element?(view, "#remove-repository-dialog", "andreasronge/retired")
    assert Repo.get(Repository, repository.id)

    view |> element("#remove-repository-dialog button", "Cancel") |> render_click()
    assert Repo.get(Repository, repository.id)

    view
    |> element("#remove-repository button", "Remove repository")
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

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    view
    |> element("#remove-repository button", "Remove repository")
    |> render_click()

    html =
      view
      |> element("#remove-repository-dialog button", "Remove repository")
      |> render_click()

    assert html =~ "has active managed work"
    assert Repo.get(Repository, repository.id)
  end

  test "clears a confirmation dialog after peer removal", %{conn: conn} do
    repository = repository_fixture(%{github_name: "peer-removed"})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    view
    |> element("#remove-repository button", "Remove repository")
    |> render_click()

    assert has_element?(view, "#remove-repository-dialog")
    assert {:ok, _repository} = Operations.remove_repository(repository.id)
    assert_redirect(view, ~p"/configuration")
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

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(ready))

    assert has_element?(view, "#repository-health", "Checkout verified")
    assert has_element?(view, "#repository-health", "GitHub read access verified")
    assert has_element?(view, "#repository-health", "Optional broker verification ready")
    assert has_element?(view, "#repository-health", "mix precommit")

    {:ok, setup_only_view, _html} =
      conn |> authenticated_conn() |> live(repository_path(setup_only))

    assert has_element?(setup_only_view, "#repository-health", "Repository contract ready")
    assert has_element?(setup_only_view, "#repository-health", "Workspace setup configured")

    assert has_element?(
             setup_only_view,
             "#repository-health",
             "broker verification is not configured"
           )

    {:ok, missing_view, _html} = conn |> authenticated_conn() |> live(repository_path(missing))

    assert has_element?(missing_view, "#repository-health", "Checkout needs attention")
    assert has_element?(missing_view, "#repository-health", "Configure an existing")
    assert has_element?(missing_view, "#repository-health", "Repository contract not checked")

    ready
    |> Repository.changeset(%{sync_status: "syncing"})
    |> Repo.update!()

    Operations.notify_changed(PtcManager.GitHub.Sync)

    assert has_element?(view, "#repository-health", "GitHub read access syncing")
    assert has_element?(view, "#repository-health", "Refreshing repository data now")
  end

  test "an untracked contract counts as no contract", %{conn: conn} do
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
      verification:
        before_publish: mix precommit
        timeout_minutes: 30
      """
    )

    repository = repository_fixture(%{github_name: "untracked-contract", local_path: root})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    # Only a contract committed on the configured branch counts, and without
    # one the repository simply has no broker verification or deployment.
    assert has_element?(view, "#repository-health", "No repository contract")
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
      verification:
        before_publish: mix precommit
        timeout_minutes: 30
      """
    )

    git!(root, ["add", ".ptc-manager.yml"])
    git!(root, ["commit", "-m", "add contract on feature only"])

    repository = repository_fixture(%{github_name: "feature-contract", local_path: root})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    # Only a contract committed on the configured branch counts, and without
    # one the repository simply has no broker verification or deployment.
    assert has_element?(view, "#repository-health", "No repository contract")
  end

  test "configures the maintainer's own triage labels per repository", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "labelled"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    view
    |> form("#add-maintainer-label", %{
      "label" => %{
        "name" => "wait",
        "role" => "park"
      }
    })
    |> render_submit()

    assert render(view) =~ "It must already exist on GitHub"
    assert has_element?(view, "#maintainer-labels", "wait")

    assert Repo.get!(Repository, repository.id).maintainer_labels == %{
             "labels" => [%{"name" => "wait", "role" => "park"}]
           }

    for reserved <- ["ptc:ready", "PTC:ready", "Ptc:Blocked"] do
      view
      |> form("#add-maintainer-label", %{
        "label" => %{
          "name" => reserved,
          "role" => "badge"
        }
      })
      |> render_submit()

      assert render(view) =~ "belong to PtcManager"
    end

    # GitHub label names are case-insensitive, so neither is a second label.
    view
    |> form("#add-maintainer-label", %{
      "label" => %{
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
    |> element("#maintainer-labels button[phx-value-name='wait']")
    |> render_click()

    assert Repo.get!(Repository, repository.id).maintainer_labels == %{"labels" => []}
  end

  test "edits the default branch and warns when GitHub's differs", %{conn: conn} do
    repository = repository_fixture(%{github_default_branch: "develop"})
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert has_element?(view, "#default-branch-mismatch", "develop")

    html =
      view
      |> form("#default-branch-form", %{"branch" => %{"name" => "develop"}})
      |> render_submit()

    assert html =~ "New work starts from and targets develop."
    assert Repo.get!(Repository, repository.id).default_branch == "develop"
    refute has_element?(view, "#default-branch-mismatch")

    html =
      view
      |> form("#default-branch-form", %{"branch" => %{"name" => "a..b"}})
      |> render_submit()

    assert html =~ "Use a branch name"

    issue = issue_fixture(repository)
    {:ok, _job} = Operations.approve_issue_directly(issue.id, "andreas")

    html =
      view
      |> form("#default-branch-form", %{"branch" => %{"name" => "main"}})
      |> render_submit()

    assert html =~
             "Active work, retained worktrees, or open managed pull requests still use develop."

    assert Repo.get!(Repository, repository.id).default_branch == "develop"
  end

  test "edits the workspace setup command and timeout", %{conn: conn} do
    repository = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    html =
      view
      |> form("#workspace-setup-form", %{
        "setup" => %{"command" => "deno install", "timeout_minutes" => "15"}
      })
      |> render_submit()

    assert html =~ "Workspace setup saved."
    assert has_element?(view, "#repository-health", "deno install · up to 15 min")

    html =
      view
      |> form("#workspace-setup-form", %{
        "setup" => %{"command" => "deno install", "timeout_minutes" => "0"}
      })
      |> render_submit()

    assert html =~ "timeout of 1 to 1440 minutes"
    assert Repo.get!(Repository, repository.id).workspace_setup_timeout_minutes == 15
  end

  test "maps a label to an integration branch from a suggestion, switches it off, and removes it",
       %{conn: conn} do
    Application.put_env(:ptc_manager, :test_github_branches, ["main", "feature/ska"])
    on_exit(fn -> Application.delete_env(:ptc_manager, :test_github_branches) end)

    repository =
      repository_fixture(%{
        github_label_names: %{"names" => ["ska", "cleanup"]},
        github_branch_names: %{"names" => ["main", "feature/ska"]}
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert has_element?(view, "#integration-branch-suggestions", "Add ska → feature/ska")
    refute has_element?(view, "#integration-branch-suggestions", "cleanup")

    view |> form("#suggest-integration-branch-ska") |> render_submit()

    assert has_element?(view, "#integration-branch-ska", "feature/ska")
    refute has_element?(view, "#integration-branch-suggestions")

    html =
      view
      |> form("#add-integration-branch", %{
        "mapping" => %{"label" => "cleanup", "branch" => "feature/cleanup"}
      })
      |> render_submit()

    assert html =~ "GitHub reports no such branch"

    view
    |> element("#integration-branch-ska button", "Switch off")
    |> render_click()

    assert has_element?(view, "#integration-branch-ska", "off")

    view
    |> element("#integration-branch-ska button", "Remove")
    |> render_click()

    refute has_element?(view, "#integration-branch-ska")
  end

  test "branch names: the default prefix and label mappings are edited on the page",
       %{conn: conn} do
    repository =
      repository_fixture(%{
        github_label_names: %{"names" => ["bug"]},
        github_branch_names: %{"names" => ["main", "hotfix"]}
      })

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert has_element?(view, "#branch-prefix-preview", "ptc-manager/issue-123-job-42")

    html =
      view
      |> form("#default-branch-prefix-form", %{"prefix" => "feature"})
      |> render_submit()

    assert html =~ "each ending in /"

    view |> form("#default-branch-prefix-form", %{"prefix" => "feature/"}) |> render_submit()
    assert has_element?(view, "#branch-prefix-preview", "feature/issue-123-job-42")

    view
    |> form("#add-branch-prefix", %{"mapping" => %{"label" => "bug", "prefix" => "bugfix/"}})
    |> render_submit()

    assert has_element?(view, "#branch-prefix-bug", "bugfix/")

    html =
      view
      |> form("#add-branch-prefix", %{"mapping" => %{"label" => "urgent", "prefix" => "hotfix/"}})
      |> render_submit()

    assert html =~ "GitHub has a branch with that name"

    view |> element("#branch-prefix-bug button", "Remove") |> render_click()
    refute has_element?(view, "#branch-prefix-bug")
  end

  test "an unknown repository returns to the Configuration list", %{conn: conn} do
    for id <- ["999999", "not-a-number"] do
      assert {:error, {:live_redirect, %{to: "/configuration", flash: flash}}} =
               conn |> authenticated_conn() |> live("/configuration/repositories/#{id}")

      assert flash["error"] =~ "no longer configured"
    end
  end

  test "a label edit keeps labels another session saved after this page loaded", %{conn: conn} do
    repository = repository_fixture()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    # Written without a change notification, so the page still holds the old list.
    repository
    |> Repository.changeset(%{
      maintainer_labels: %{"labels" => [%{"name" => "ux", "role" => "badge"}]}
    })
    |> Repo.update!()

    view
    |> form("#add-maintainer-label", %{"label" => %{"name" => "wait", "role" => "park"}})
    |> render_submit()

    assert Repo.get!(Repository, repository.id).maintainer_labels == %{
             "labels" => [
               %{"name" => "ux", "role" => "badge"},
               %{"name" => "wait", "role" => "park"}
             ]
           }
  end

  test "names the GitHub labels a repository is still missing", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "unlabelled"})

    {:ok, view, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert has_element?(
             view,
             "#repository-health",
             "GitHub labels not checked"
           )

    repository
    |> Repository.changeset(%{
      github_label_names: %{"names" => ["PTC:Ready", "ptc:blocked", "bug"]},
      github_labels_checked_at: DateTime.utc_now(),
      maintainer_labels: %{"labels" => [%{"name" => "wait", "role" => "park"}]}
    })
    |> Repo.update!()

    {:ok, partial, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    detail = partial |> element("#repository-health") |> render()
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

    {:ok, complete, _html} = conn |> authenticated_conn() |> live(repository_path(repository))

    assert has_element?(
             complete,
             "#repository-health",
             "GitHub labels present"
           )
  end

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "maintainer")
  end

  defp repository_path(repository), do: ~p"/configuration/repositories/#{repository.id}"

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
