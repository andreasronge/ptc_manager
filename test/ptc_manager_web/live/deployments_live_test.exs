defmodule PtcManagerWeb.DeploymentsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

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

  test "explains how to enable deployment when no repository opted in", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/deployments")

    assert has_element?(
             view,
             "#no-deployments-configured",
             "No repository has deployment enabled"
           )
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
