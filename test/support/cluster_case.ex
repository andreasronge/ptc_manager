defmodule PtcManager.ClusterCase do
  @moduledoc "Configures this test run as member `alpha` of a two- or three-member cluster."

  import ExUnit.Callbacks

  @keys [
    :cluster_members,
    :cluster_secret,
    :machine_id,
    :machine_id_configured,
    :cluster_http_client
  ]

  def members do
    %{
      "alpha" => "https://alpha.example.ts.net",
      "beta" => "https://beta.example.ts.net",
      "gamma" => "https://100.100.1.3"
    }
  end

  def secret, do: String.duplicate("s", 40)

  @doc "Joins the cluster as `alpha` with the given peer responders until the test ends."
  def join_cluster!(responders, members \\ members()) do
    previous = Map.new(@keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)

      PtcManager.Cluster.PeerPoller.reset()
    end)

    Application.put_env(:ptc_manager, :cluster_members, members)
    Application.put_env(:ptc_manager, :cluster_secret, secret())
    Application.put_env(:ptc_manager, :machine_id, "alpha")
    Application.put_env(:ptc_manager, :machine_id_configured, true)

    Application.put_env(
      :ptc_manager,
      :cluster_http_client,
      PtcManager.TestPeerClient.new(responders)
    )

    PtcManager.Cluster.PeerPoller.reset()
    :ok
  end
end
