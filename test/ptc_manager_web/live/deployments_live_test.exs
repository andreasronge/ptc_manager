defmodule PtcManagerWeb.DeploymentsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Deployments.Deployment
  alias PtcManager.Repo

  defmodule RevisionSource do
    def latest(_repository), do: {:ok, String.duplicate("b", 40)}
  end

  test "shows that a newer default-branch revision is available", %{conn: conn} do
    previous_source = Application.get_env(:ptc_manager, :deployment_revision_source)
    previous_sha = Application.get_env(:ptc_manager, :deployed_sha)
    Application.put_env(:ptc_manager, :deployment_revision_source, RevisionSource)
    Application.put_env(:ptc_manager, :deployed_sha, String.duplicate("a", 40))

    on_exit(fn ->
      restore(:deployment_revision_source, previous_source)
      restore(:deployed_sha, previous_sha)
    end)

    repository = deployable_repository()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/deployments")
    render_async(view, 1_000)

    assert has_element?(view, "nav", "Deploy")
    assert has_element?(view, "#update-available-#{repository.id}", "Update available")
    assert has_element?(view, "#deployment-repository-#{repository.id}", "aaaaaaaaaaaa")
    assert has_element?(view, "#deployment-repository-#{repository.id}", "bbbbbbbbbbbb")
    assert has_element?(view, "#deploy-when-safe-#{repository.id}:not([disabled])")
  end

  # A deployment the host guard refuses finishes seconds after it is requested,
  # so the banner for an active deployment is gone before anyone can read it and
  # the button simply comes back. The outcome has to appear where it was asked
  # for, with the instant it happened.
  test "reports the last deployment outcome beside the deploy button", %{conn: conn} do
    previous_source = Application.get_env(:ptc_manager, :deployment_revision_source)
    Application.put_env(:ptc_manager, :deployment_revision_source, RevisionSource)
    on_exit(fn -> restore(:deployment_revision_source, previous_source) end)

    repository = deployable_repository()
    requested_at = ~U[2026-09-03 16:48:51.393524Z]

    %Deployment{}
    |> Deployment.changeset(%{
      repository_id: repository.id,
      requested_sha: String.duplicate("c", 40),
      state: "failed",
      requested_by: "maintainer",
      requested_at: requested_at,
      started_at: requested_at,
      finished_at: DateTime.add(requested_at, 2, :second),
      status_text: "Deployment stopped safely; inspect the retained service output.",
      last_error: "refusing to deploy while 1 managed agent run(s) are active",
      deployment_command: "./scripts/ptc/deploy",
      deployment_timeout_minutes: 20
    })
    |> Repo.insert!()

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/deployments")
    render_async(view, 1_000)

    card = "#last-deployment-#{repository.id}"

    assert has_element?(view, card, "Last attempt · Failed")
    assert has_element?(view, card, "refusing to deploy while 1 managed agent run(s) are active")
    assert has_element?(view, card, "03 Sep 2026 · 16:48:53 UTC")
    assert has_element?(view, "#deployment-#{Repo.one!(Deployment).id}", "Took 2s")
  end

  test "explains how to enable deployment when no repository opted in", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/deployments")

    assert has_element?(
             view,
             "#no-deployments-configured",
             "No repository has deployment enabled"
           )
  end

  # The versions on the machine are not written anywhere a maintainer can read
  # from the console otherwise, and the state that matters most is a program the
  # deployment does not own.
  test "reports what the machine links against what this release pins", %{conn: conn} do
    root =
      Path.join(System.tmp_dir!(), "ptc-deployments-live-#{System.unique_integer([:positive])}")

    link_dir = Path.join(root, "bin")
    install_root = Path.join(root, "opt")
    codex = Map.fetch!(PtcManager.Toolchain.pinned(), "codex")
    File.mkdir_p!(link_dir)
    File.mkdir_p!(Path.join(install_root, "ptc-manager-codex-#{codex}"))
    File.ln_s!("/opt/codex/0.1.0/bin/codex", Path.join(link_dir, "codex"))

    previous_link_dir = Application.get_env(:ptc_manager, :toolchain_link_dir)
    previous_install_root = Application.get_env(:ptc_manager, :toolchain_install_root)
    Application.put_env(:ptc_manager, :toolchain_link_dir, link_dir)
    Application.put_env(:ptc_manager, :toolchain_install_root, install_root)

    on_exit(fn ->
      restore(:toolchain_link_dir, previous_link_dir)
      restore(:toolchain_install_root, previous_install_root)
      File.rm_rf!(root)
    end)

    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/deployments")

    assert has_element?(view, "#machine-software", "Machine software")
    assert has_element?(view, "#program-codex", codex)
    assert has_element?(view, "#program-codex", "Not this release")
    assert has_element?(view, "#program-codex", "/opt/codex/0.1.0/bin/codex")
    assert has_element?(view, "#machine-software", "links something this release does not pin")
    assert has_element?(view, "#program-herdr", "Not on this machine")
  end

  defp deployable_repository do
    suffix = System.unique_integer([:positive, :monotonic])
    owner = "web-deploy-owner-#{suffix}"
    name = "web-deploy-repo-#{suffix}"
    path = Path.join(System.tmp_dir!(), "#{owner}-#{name}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    File.write!(
      Path.join(path, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: ./scripts/ptc/bootstrap
        timeout_minutes: 10
      deployment:
        command: ./scripts/ptc/deploy
        timeout_minutes: 20
      """
    )

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["remote", "add", "origin", "git@github.com:#{owner}/#{name}.git"])
    git!(path, ["add", ".ptc-manager.yml"])
    git!(path, ["commit", "-m", "add deployment contract"])

    repository_fixture(%{github_owner: owner, github_name: name, local_path: path, enabled: true})
  end

  defp git!(path, args) do
    {_output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore(key, value), do: Application.put_env(:ptc_manager, key, value)

  defp authenticated_conn(conn) do
    conn
    |> init_test_session(%{})
    |> put_session(:authenticated, true)
    |> put_session(:actor, "andreas")
  end
end
