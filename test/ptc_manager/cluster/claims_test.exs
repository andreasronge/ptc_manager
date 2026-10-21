defmodule PtcManager.Cluster.ClaimsTest do
  use PtcManager.DataCase, async: false

  import PtcManager.ClusterCase

  alias PtcManager.Cluster.{ClaimIntent, Claims}
  alias PtcManager.Operations
  alias PtcManager.Operations.{AuditEvent, Repository}
  alias PtcManager.TestPeerClient

  defp clear, do: fn _path, _headers -> {200, TestPeerClient.status("beta")} end

  defp peers(beta, gamma \\ nil) do
    %{
      "beta" => beta,
      "gamma" => gamma || fn _path, _headers -> {200, TestPeerClient.status("gamma")} end
    }
  end

  defp claiming(member, key, claim) do
    fn _path, _headers ->
      {200,
       TestPeerClient.status(member, %{
         "repositories" => [%{"repository" => key, "claim" => claim}]
       })}
    end
  end

  test "a repository's claim state comes from its own records" do
    enabled = repository_fixture(%{github_owner: "Acme", github_name: "Enabled"})
    disabled = repository_fixture(%{github_owner: "acme", github_name: "idle", enabled: false})
    busy = repository_fixture(%{github_owner: "acme", github_name: "busy", enabled: false})
    pending = repository_fixture(%{github_owner: "acme", github_name: "pending", enabled: false})

    issue = issue_fixture(busy)
    proposal_fixture(issue)
    {:ok, _job} = Operations.approve_issue(issue.id, "maintainer")

    Repo.insert!(%ClaimIntent{
      repository_key: "acme/pending",
      token: "t",
      actor: "maintainer",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    })

    snapshot = Claims.snapshot([enabled, disabled, busy, pending])

    assert snapshot.states == %{
             "acme/enabled" => "enabled",
             "acme/idle" => "none",
             "acme/busy" => "live_work",
             "acme/pending" => "pending"
           }

    assert snapshot.blockers["acme/busy"] == ["1 unfinished job"]
    assert [%{"repository" => "acme/pending"}] = snapshot.intents
  end

  test "enabling on a member claims the repository after every peer agrees" do
    join_cluster!(peers(clear()))
    repository = repository_fixture(%{enabled: false})

    assert {:ok, %Repository{enabled: true}} =
             Operations.set_repository_enabled(repository.id, true, "maintainer")

    event = Repo.get_by!(AuditEvent, action: "repository.enabled", target_id: repository.id)
    assert Enum.map(event.details["peer_checks"], & &1["result"]) == ["clear", "clear"]
    assert event.details["machine_id"] == "alpha"
    assert Repo.aggregate(ClaimIntent, :count) == 0
  end

  test "a claim is refused while any peer claims, is claiming, disagrees, or cannot answer" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api", enabled: false})

    for {beta, result} <- [
          {claiming("beta", "acme/api", "enabled"), "claimed"},
          {claiming("beta", "acme/api", "live_work"), "claimed"},
          {fn _p, _h ->
             {200, TestPeerClient.status("beta", %{"intents" => [%{"repository" => "acme/api"}]})}
           end, "pending"},
          {fn _p, _h ->
             {200, TestPeerClient.status("beta", %{"membership_revision" => "other"})}
           end, "revision_mismatch"},
          {fn _p, _h -> {200, TestPeerClient.status("beta", %{"protocol_version" => 2})} end,
           "incompatible"},
          {fn _p, _h -> {403, %{"member" => false}} end, "not_member"},
          {fn _p, _h -> :down end, "unreachable"},
          {fn _p, _h -> {:raw, 200, [], "{}"} end, "unreachable"}
        ] do
      join_cluster!(peers(beta))

      assert {:error, {:claim_refused, :claim_refused, checks}} =
               Operations.set_repository_enabled(repository.id, true, "maintainer")

      assert %{"machine_id" => "beta", "result" => ^result} =
               Enum.find(checks, &(&1["machine_id"] == "beta"))

      refute Repo.get!(Repository, repository.id).enabled
      assert Repo.aggregate(ClaimIntent, :count) == 0
    end
  end

  test "an intent is announced before the peers are asked, so a simultaneous claim sees it" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api", enabled: false})
    test = self()

    beta = fn _path, _headers ->
      # While beta is being asked, alpha's own status already shows the intent.
      send(test, {:alpha_claims, Claims.snapshot([Repo.get!(Repository, repository.id)]).states})
      {200, TestPeerClient.status("beta")}
    end

    join_cluster!(peers(beta))

    assert {:ok, _repository} =
             Operations.set_repository_enabled(repository.id, true, "maintainer")

    assert_received {:alpha_claims, %{"acme/api" => "pending"}}
  end

  test "a failing import rolls the whole claim back" do
    join_cluster!(peers(clear()))
    repository = repository_fixture(%{enabled: false})

    assert {:error, :import_failed, [_beta, _gamma]} =
             Claims.acquire(repository.id, "maintainer", fn _repository, _checks ->
               {:error, :import_failed}
             end)

    refute Repo.get!(Repository, repository.id).enabled
    assert Repo.aggregate(ClaimIntent, :count) == 0
  end

  test "repositories differing only in case are one repository" do
    repository_fixture(%{github_owner: "Acme", github_name: "Api"})

    assert {:error, changeset} =
             Operations.create_repository(%{github_owner: "acme", github_name: "api"})

    assert changeset.errors[:github_owner]
  end

  test "a malformed status document never clears a claim" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api", enabled: false})

    for malformed <- [
          Map.delete(TestPeerClient.status("beta"), "repositories"),
          TestPeerClient.status("beta", %{"intents" => "none"}),
          TestPeerClient.status("beta", %{
            "repositories" => [%{"repository" => "acme/api", "claim" => "mine"}]
          }),
          TestPeerClient.status("gamma")
        ] do
      join_cluster!(peers(fn _p, _h -> {200, malformed} end))

      assert {:error, {:claim_refused, :claim_refused, checks}} =
               Operations.set_repository_enabled(repository.id, true, "maintainer")

      assert %{"result" => "unreachable", "detail" => ":invalid_status"} =
               Enum.find(checks, &(&1["machine_id"] == "beta"))
    end
  end

  test "a member creates repositories disabled, also from string-keyed parameters" do
    join_cluster!(peers(clear()))

    assert {:ok, %Repository{enabled: false}} =
             Operations.create_repository(%{
               "github_owner" => "acme",
               "github_name" => "strings",
               "enabled" => "true"
             })
  end

  test "a member creates repositories disabled and creates no work for a disabled one" do
    join_cluster!(peers(clear()))

    {:ok, repository} =
      Operations.create_repository(%{github_owner: "acme", github_name: "new", enabled: true})

    refute repository.enabled

    issue = issue_fixture(repository)
    proposal_fixture(issue)
    assert {:error, :repository_disabled} = Operations.approve_issue(issue.id, "maintainer")
  end
end
