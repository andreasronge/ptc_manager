defmodule PtcManager.Cluster.PeerTest do
  use ExUnit.Case, async: false

  import PtcManager.ClusterCase

  alias PtcManager.Cluster.Peer
  alias PtcManager.TestPeerClient

  defp answering(document), do: %{"beta" => fn _p, _h -> {200, document} end}

  test "a well-formed status document is returned with the measured clock skew" do
    join_cluster!(answering(TestPeerClient.status("beta")))
    assert {:ok, %{"machine_id" => "beta", "_clock_skew_s" => skew}} = Peer.fetch_status("beta")
    assert abs(skew) <= 1
  end

  test "ambiguous ownership data is refused" do
    for repositories <- [
          [
            %{"repository" => "acme/api", "claim" => "none"},
            %{"repository" => "acme/api", "claim" => "enabled"}
          ],
          [%{"repository" => "Acme/Api", "claim" => "none"}],
          [%{"repository" => "acme", "claim" => "none"}]
        ] do
      join_cluster!(answering(TestPeerClient.status("beta", %{"repositories" => repositories})))
      assert {:error, :invalid_status} = Peer.fetch_status("beta")
    end

    join_cluster!(
      answering(TestPeerClient.status("beta", %{"intents" => [%{"repository" => "Acme/Api"}]}))
    )

    assert {:error, :invalid_status} = Peer.fetch_status("beta")
  end

  test "an unsigned or wrongly signed answer is refused" do
    join_cluster!(%{"beta" => fn _p, _h -> {:raw, 200, [], ~s({"machine_id":"beta"})} end})
    assert {:error, {:bad_response_signature, _reason}} = Peer.fetch_status("beta")
  end
end
