defmodule PtcManager.ClusterTest do
  use ExUnit.Case, async: false

  alias PtcManager.Cluster

  @keys [
    :cluster_members,
    :cluster_secret,
    :machine_id,
    :machine_id_configured,
    :cluster_allow_insecure_loopback
  ]

  setup do
    previous = Map.new(@keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    :ok
  end

  defp configure(members, opts \\ []) do
    Application.put_env(:ptc_manager, :cluster_members, members)

    Application.put_env(
      :ptc_manager,
      :cluster_secret,
      Keyword.get(opts, :secret, String.duplicate("s", 32))
    )

    Application.put_env(:ptc_manager, :machine_id, Keyword.get(opts, :id, "alpha"))

    Application.put_env(
      :ptc_manager,
      :machine_id_configured,
      Keyword.get(opts, :configured, true)
    )

    Application.put_env(
      :ptc_manager,
      :cluster_allow_insecure_loopback,
      Keyword.get(opts, :loopback, false)
    )
  end

  test "an unclustered console needs nothing" do
    Application.delete_env(:ptc_manager, :cluster_members)
    refute Cluster.enabled?()
    assert Cluster.validate!() == :ok
  end

  test "a valid membership boots" do
    configure(%{
      "alpha" => "https://alpha.tail1.ts.net",
      "beta" => "https://100.64.0.7",
      "gamma" => "https://[fd7a:115c:a1e0::5]"
    })

    assert Cluster.validate!() == :ok

    assert Cluster.peers() == [
             {"beta", "https://100.64.0.7"},
             {"gamma", "https://[fd7a:115c:a1e0::5]"}
           ]
  end

  test "boot refuses an unusable membership" do
    members = %{"alpha" => "https://alpha.tail1.ts.net", "beta" => "https://beta.tail1.ts.net"}

    configure(members, id: "delta")
    assert_raise ArgumentError, ~r/not in PTC_CLUSTER_MEMBERS/, &Cluster.validate!/0

    configure(members, secret: "short")
    assert_raise ArgumentError, ~r/PTC_CLUSTER_SECRET/, &Cluster.validate!/0

    configure(members, configured: false)
    assert_raise ArgumentError, ~r/PTC_MACHINE_ID is required/, &Cluster.validate!/0

    configure(%{members | "beta" => "https://beta.example.com"})
    assert_raise ArgumentError, ~r/beta must use/, &Cluster.validate!/0

    configure(%{members | "beta" => "https://100.200.0.1"})
    assert_raise ArgumentError, ~r/beta must use/, &Cluster.validate!/0

    configure(%{members | "beta" => "http://beta.tail1.ts.net"})
    assert_raise ArgumentError, ~r/beta must use/, &Cluster.validate!/0

    configure(%{members | "beta" => "http://127.0.0.1:4101"})
    assert_raise ArgumentError, ~r/beta must use/, &Cluster.validate!/0

    configure(%{members | "beta" => "http://127.0.0.1:4101"}, loopback: true)
    assert Cluster.validate!() == :ok
  end

  test "the membership revision depends on the members, not their order" do
    a = %{"alpha" => "https://a.ts.net", "beta" => "https://b.ts.net"}
    b = Map.new(Enum.reverse(Map.to_list(a)))

    assert Cluster.membership_revision(a) == Cluster.membership_revision(b)

    refute Cluster.membership_revision(a) ==
             Cluster.membership_revision(Map.put(a, "gamma", "https://g.ts.net"))
  end
end
