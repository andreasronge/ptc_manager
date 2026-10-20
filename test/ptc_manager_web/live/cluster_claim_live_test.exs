defmodule PtcManagerWeb.ClusterClaimLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import PtcManager.ClusterCase

  alias PtcManager.Cluster.{PeerPoller, RepositorySettings}
  alias PtcManager.Operations.Repository
  alias PtcManager.Repo
  alias PtcManager.TestPeerClient

  setup do
    checkout =
      Path.join(System.tmp_dir!(), "ptc-claim-live-#{System.unique_integer([:positive])}")

    File.mkdir_p!(checkout)
    on_exit(fn -> File.rm_rf!(checkout) end)
    %{checkout: checkout}
  end

  test "previews the source's settings and claims with one confirmation", %{
    conn: conn,
    checkout: checkout
  } do
    repository =
      repository_fixture(%{github_owner: "acme", github_name: "api", local_path: checkout})

    document =
      repository
      |> RepositorySettings.export()
      |> put_in(["settings", "auto_fix_daily_limit"], 7)
      |> Map.put("agent_environment_variable_names", ["API_TOKEN"])
      |> then(&Map.put(&1, "digest", RepositorySettings.digest(&1)))

    join_cluster!(%{
      "beta" => fn
        "/api/peer/v1/status", _h ->
          {200,
           TestPeerClient.status("beta", %{
             "repositories" => [%{"repository" => "acme/api", "claim" => "none"}]
           })}

        "/api/peer/v1/repositories/acme/api/settings", _h ->
          {200, document}
      end,
      "gamma" => fn _p, _h -> {200, TestPeerClient.status("gamma")} end
    })

    repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()

    {:ok, view, _html} =
      conn |> authenticated_conn() |> live(~p"/cluster/claim/acme/api?from=beta")

    assert render_async(view) =~ "Settings that change"
    assert has_element?(view, "#claim-readiness", "Checkout present and readable")
    assert has_element?(view, "#claim-setting-auto_fix_daily_limit", "7")
    assert has_element?(view, "#claim-variables", "API_TOKEN")

    view |> element("#confirm-claim") |> render_click()
    assert_redirect(view, ~p"/configuration/repositories/#{repository.id}")
    assert Repo.get!(Repository, repository.id).enabled
  end

  test "names the next step when the repository is not onboarded here", %{conn: conn} do
    join_cluster!(%{})

    {:ok, view, _html} =
      conn |> authenticated_conn() |> live(~p"/cluster/claim/acme/missing?from=beta")

    assert has_element?(view, "#claim-not-onboarded", "Onboard it")
  end

  test "the source page lists what still holds the claim, then offers capable members", %{
    conn: conn
  } do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})

    join_cluster!(%{
      "beta" => fn _p, _h ->
        {200, TestPeerClient.status("beta", %{"machine_name" => "Beta box"})}
      end,
      "gamma" => fn _p, _h -> :down end
    })

    PeerPoller.poll_now()

    {:ok, view, _html} =
      conn |> authenticated_conn() |> live(~p"/configuration/repositories/#{repository.id}")

    assert has_element?(view, "#move-repository", "Homed here")

    repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()

    {:ok, view, _html} =
      conn |> authenticated_conn() |> live(~p"/configuration/repositories/#{repository.id}")

    assert has_element?(view, "#move-ready", "Ready to claim on another member")

    assert has_element?(
             view,
             ~s(#move-target-beta a[href="https://beta.example.ts.net/cluster/claim/acme/api?from=alpha"])
           )

    # A member that has not answered is listed without a claim link.
    assert has_element?(view, "#move-target-gamma")
    refute has_element?(view, "#move-target-gamma a")
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
