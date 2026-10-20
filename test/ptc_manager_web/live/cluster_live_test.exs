defmodule PtcManagerWeb.ClusterLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  import PtcManager.ClusterCase

  alias PtcManager.Cluster.PeerPoller
  alias PtcManager.TestPeerClient

  test "an unclustered console explains how to join", %{conn: conn} do
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/cluster")
    assert has_element?(view, "#cluster-disabled", "PTC_CLUSTER_MEMBERS")
    refute has_element?(view, "#machine-switcher")
  end

  test "lists every member and each repository's home", %{conn: conn} do
    repository_fixture(%{github_owner: "acme", github_name: "local"})

    join_cluster!(%{
      "beta" => fn _p, _h ->
        {200,
         TestPeerClient.status("beta", %{
           "machine_name" => "Beta box",
           "repositories" => [
             %{"repository" => "acme/api", "claim" => "enabled", "claim_blockers" => ["enabled"]}
           ]
         })}
      end,
      "gamma" => fn _p, _h -> :down end
    })

    PeerPoller.poll_now()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/cluster")

    assert has_element?(view, "#machine-alpha", "this machine")
    assert has_element?(view, "#machine-beta", "Beta box")
    assert has_element?(view, "#machine-beta", "healthy")
    assert has_element?(view, "#cluster-repository-acme\\/api", "beta")
    assert has_element?(view, "#cluster-repository-acme\\/local", "alpha")
    assert has_element?(view, "#cluster-banner", "Waiting to hear from every member")

    assert has_element?(
             view,
             ~s(#machine-switcher a#switch-to-beta[href="https://beta.example.ts.net/cluster"])
           )
  end

  test "shows each member's tools, drift, and a move link at the repository's home", %{conn: conn} do
    join_cluster!(%{
      "beta" => fn _p, _h ->
        {200,
         TestPeerClient.status("beta", %{
           "protocol_version" => 1,
           "deployed_sha" => String.duplicate("c", 40),
           "inventory" => %{
             "pane" => %{
               "captured_at" => DateTime.to_iso8601(DateTime.utc_now()),
               "stale" => false,
               "tools" => %{
                 "docker" => %{"status" => "ok", "version" => "27.5.1", "detail" => nil}
               }
             },
             "setup" => nil
           },
           "repositories" => [
             %{"repository" => "acme/api", "claim" => "enabled", "requirements" => []}
           ]
         })}
      end,
      "gamma" => fn _p, _h -> :down end
    })

    PeerPoller.poll_now()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/cluster")

    assert has_element?(view, "#machine-beta-tools-docker-pane", "27.5.1")
    assert has_element?(view, "#cluster-drift", "beta: deployed revision cccccccccccc")

    assert has_element?(
             view,
             ~s(#cluster-repository-acme\\/api a[href="https://beta.example.ts.net/repositories/acme/api"])
           )
  end

  test "one member's malformed display data cannot break the page, and old inventories read stale",
       %{conn: conn} do
    long_ago = DateTime.utc_now() |> DateTime.add(-7_200, :second) |> DateTime.to_iso8601()

    join_cluster!(%{
      "beta" => fn _p, _h ->
        {200,
         TestPeerClient.status("beta", %{
           "machine_name" => %{"not" => "a name"},
           "capacity" => %{"cpu_percent" => "unknown"},
           "agent_logins" => %{"codex" => %{}},
           "jobs" => [%{"repository" => "acme/api", "url" => 7}, "junk"],
           "inventory" => %{
             "pane" => %{
               "captured_at" => long_ago,
               "stale" => false,
               "tools" => %{
                 "docker" => %{"status" => "ok", "version" => "27.5.1"},
                 "git" => "odd"
               }
             },
             "setup" => "odd"
           },
           "repositories" => [
             %{
               "repository" => "acme/api",
               "claim" => "enabled",
               "requirements" => [nil, %{"name" => "docker", "version" => "newest"}],
               "claim_blockers" => [1]
             }
           ]
         })}
      end,
      "gamma" => fn _p, _h -> :down end
    })

    PeerPoller.poll_now()
    {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/cluster")

    assert has_element?(view, "#machine-beta", "beta")
    assert has_element?(view, "#machine-beta-tools", "stale")

    assert has_element?(
             view,
             "#cluster-repository-acme\\/api",
             "docker inventory is stale"
           )
  end

  test "the switcher keeps a repository page by owner and name", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "Acme", github_name: "Api"})
    join_cluster!(%{})

    {:ok, view, _html} =
      conn |> authenticated_conn() |> live(~p"/configuration/repositories/#{repository.id}")

    assert has_element?(
             view,
             ~s(a#switch-to-beta[href="https://beta.example.ts.net/repositories/Acme/Api"])
           )
  end

  test "a repository link resolves owner and name to this console's record", %{conn: conn} do
    repository = repository_fixture(%{github_owner: "Acme", github_name: "Api"})
    conn = authenticated_conn(conn)

    assert redirected_to(get(conn, "/repositories/acme/api")) ==
             "/configuration/repositories/#{repository.id}"

    assert redirected_to(get(conn, "/repositories/acme/missing")) == "/cluster"
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
