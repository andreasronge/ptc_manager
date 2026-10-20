defmodule PtcManager.Cluster.PeerPollerTest do
  use PtcManager.DataCase, async: false

  import PtcManager.ClusterCase

  alias PtcManager.Cluster.{Fence, PeerPoller}
  alias PtcManager.Machine.Gate
  alias PtcManager.Operations.{AuditEvent, Repository}
  alias PtcManager.TestPeerClient

  defp healthy(member, overrides \\ %{}),
    do: fn _path, _headers -> {200, TestPeerClient.status(member, overrides)} end

  defp enabled_repository(attrs) do
    attrs
    |> repository_fixture()
    |> Repository.changeset(%{enabled: true})
    |> Repo.update!()
  end

  test "a member admits nothing until one round has heard from every peer" do
    join_cluster!(%{"beta" => healthy("beta"), "gamma" => fn _p, _h -> :down end})
    repository = enabled_repository(%{github_owner: "acme", github_name: "api"})

    refute PeerPoller.current().startup_complete?
    assert Gate.check(repository) == {:error, :cluster_fenced}
    assert Fence.admission(repository) == {:error, :cluster_startup}
    assert repository.id in Gate.unsatisfied_repository_ids()
    assert Fence.console_banner() =~ "Waiting to hear from every member"

    PeerPoller.poll_now()
    refute PeerPoller.current().startup_complete?
    assert PeerPoller.current().members["beta"].health == "healthy"

    join_cluster!(%{"beta" => healthy("beta"), "gamma" => healthy("gamma")})
    PeerPoller.poll_now()

    assert PeerPoller.current().startup_complete?
    assert Gate.check(repository) == :ok
    assert Fence.console_banner() == nil

    assert Repo.exists?(
             from event in AuditEvent, where: event.action == "cluster.startup_fence_lifted"
           )
  end

  test "a malformed document does not lift the startup fence" do
    join_cluster!(%{
      "beta" => fn _p, _h -> {200, Map.delete(TestPeerClient.status("beta"), "intents")} end,
      "gamma" => healthy("gamma")
    })

    PeerPoller.poll_now()
    refute PeerPoller.current().startup_complete?
  end

  test "an incompatible peer keeps the startup fence and is shown as incompatible" do
    join_cluster!(%{
      "beta" => healthy("beta", %{"protocol_version" => 99}),
      "gamma" => healthy("gamma")
    })

    PeerPoller.poll_now()
    cluster = PeerPoller.current()
    assert cluster.members["beta"].health == "incompatible"
    refute cluster.startup_complete?
  end

  test "a repository another member also claims stops admitting here" do
    repository = enabled_repository(%{github_owner: "Acme", github_name: "Api"})
    other = enabled_repository(%{github_owner: "acme", github_name: "other"})

    join_cluster!(%{
      "beta" =>
        healthy("beta", %{
          "repositories" => [%{"repository" => "acme/api", "claim" => "live_work"}]
        }),
      "gamma" => healthy("gamma")
    })

    # A conflict found at startup keeps the startup fence too.
    PeerPoller.poll_now()
    refute PeerPoller.current().startup_complete?

    # On a member that is already running, it fences only that repository.
    PeerPoller.put(%{startup_complete?: true})
    PeerPoller.poll_now()
    cluster = PeerPoller.current()
    assert cluster.conflicts == ["acme/api"]
    assert Fence.admission(repository) == {:error, :ownership_conflict}
    assert Fence.admission(other) == :ok
    assert Fence.console_banner() =~ "also claims acme/api"
  end

  test "a peer that refuses this machine as a member fences all admission" do
    repository = enabled_repository(%{github_owner: "acme", github_name: "api"})

    join_cluster!(%{
      "beta" => fn _p, _h -> {403, %{"member" => false}} end,
      "gamma" => healthy("gamma")
    })

    PeerPoller.put(%{startup_complete?: true})
    PeerPoller.poll_now()

    assert PeerPoller.current().refused_by == ["beta"]
    assert Fence.admission(repository) == {:error, :not_member}
    assert Fence.console_banner() =~ "beta does not count this machine as a member"

    # A refusal stands through a later transport failure.
    join_cluster_keeping_state!(%{"beta" => fn _p, _h -> :down end, "gamma" => healthy("gamma")})
    PeerPoller.poll_now()
    assert PeerPoller.current().refused_by == ["beta"]
    assert Fence.admission(repository) == {:error, :not_member}

    # It is lifted only when the member answers again.
    join_cluster_keeping_state!(%{"beta" => healthy("beta"), "gamma" => healthy("gamma")})
    PeerPoller.poll_now()
    assert PeerPoller.current().refused_by == []
  end

  test "a peer silent for a minute becomes unreachable, and transitions are audited once" do
    join_cluster!(%{"beta" => healthy("beta"), "gamma" => healthy("gamma")})
    PeerPoller.poll_now()
    PeerPoller.poll_now()

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.action == "cluster.member_health_changed"),
             :count
           ) == 2

    long_ago = DateTime.add(DateTime.utc_now(), -120, :second)
    cluster = PeerPoller.current()
    beta = %{cluster.members["beta"] | last_success_at: long_ago}
    PeerPoller.put(%{cluster | members: Map.put(cluster.members, "beta", beta)})

    join_cluster_keeping_state!(%{"beta" => fn _p, _h -> :down end, "gamma" => healthy("gamma")})
    PeerPoller.poll_now()

    assert PeerPoller.current().members["beta"].health == "unreachable"
    # A partition does not fence a member that did not restart.
    assert PeerPoller.current().startup_complete?
  end

  # Swaps the responders without resetting what the poller has learned.
  defp join_cluster_keeping_state!(responders) do
    Application.put_env(:ptc_manager, :cluster_http_client, TestPeerClient.new(responders))
  end

  test "the operator state carries the cluster as the poller last saw it" do
    join_cluster!(%{
      "beta" =>
        healthy("beta", %{"repositories" => [%{"repository" => "acme/api", "claim" => "enabled"}]}),
      "gamma" => healthy("gamma")
    })

    PeerPoller.poll_now()
    cluster = PtcManager.OperatorState.snapshot().cluster

    assert cluster.enabled
    assert cluster.startup_complete

    assert [
             %{
               id: "beta",
               health: "healthy",
               claims: [%{repository: "acme/api", claim: "enabled"}]
             },
             %{id: "gamma"}
           ] =
             cluster.members
  end

  test "a disabled repository is not admitted on a member" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "off"})
    join_cluster!(%{"beta" => healthy("beta"), "gamma" => healthy("gamma")})
    PeerPoller.poll_now()

    disabled = repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()
    assert Fence.admission(disabled) == {:error, :repository_disabled}
  end
end
