defmodule PtcManager.Cluster.MultiMemberTest do
  @moduledoc """
  Real cluster members against each other.

  Each member is a `:peer` node running the whole application with its own
  SQLite file, HTTP port, machine id, and member map. Herdr, GitHub, and
  dispatch stay off, as in the rest of the suite; only the cluster layer is
  real: members sign, serve, poll, claim, and fence over loopback HTTP.
  """

  use ExUnit.Case, async: false

  @moduletag :nightly
  @moduletag timeout: 300_000

  @secret String.duplicate("integration-secret-", 3)

  alias PtcManager.Cluster.{Claims, Fence, Move, PeerPoller}
  alias PtcManager.Machine.Gate
  alias PtcManager.Operations
  alias PtcManager.Operations.Repository

  setup do
    root = Path.join(System.tmp_dir!(), "ptc-cluster-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  ## Harness

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp members(ports), do: Map.new(ports, fn {id, port} -> {id, "http://127.0.0.1:#{port}"} end)

  defp start_member(root, id, port, members, opts \\ []) do
    database = Keyword.get(opts, :database, Path.join(root, "#{id}.db"))
    test_database = Application.fetch_env!(:ptc_manager, PtcManager.Repo)[:database]
    dev_database = Path.expand("../../../ptc_manager_dev.db", __DIR__)

    # Members never share a database, and none of them may touch the suite's
    # or the developer's.
    refute Path.expand(database) in [Path.expand(test_database), dev_database]

    # An anonymous VM controlled over standard IO: no distribution, no epmd.
    {:ok, peer, :nonode@nohost} = :peer.start_link(%{connection: :standard_io})

    :ok = :peer.call(peer, :code, :add_pathsz, [:code.get_path()])
    # Pool connections racing the first WAL setup log retries; assertions say
    # what matters.
    :ok = :peer.call(peer, :logger, :set_primary_config, [:level, :critical])

    env =
      Application.get_all_env(:ptc_manager)
      |> Keyword.merge(
        machine_id: id,
        machine_name: "Member #{id}",
        machine_id_configured: true,
        cluster_members: members,
        cluster_secret: @secret,
        cluster_allow_insecure_loopback: true,
        cluster_poll_interval_ms: 0,
        cluster_unreachable_after_ms: 1_000,
        tool_inventory_enabled: false,
        tool_inventory_dir: Path.join(root, "#{id}-inventory")
      )
      |> Keyword.put(PtcManager.Repo,
        database: database,
        pool_size: 5,
        busy_timeout: 5_000,
        pool: DBConnection.ConnectionPool
      )
      |> Keyword.put(
        PtcManagerWeb.Endpoint,
        Keyword.merge(Application.fetch_env!(:ptc_manager, PtcManagerWeb.Endpoint),
          http: [ip: {127, 0, 0, 1}, port: port],
          server: true
        )
      )
      |> Keyword.merge(Keyword.take(opts, [:cluster_protocol_version]))

    :ok = :peer.call(peer, Application, :load, [:ptc_manager])

    for {key, value} <- env,
        do: :ok = :peer.call(peer, Application, :put_env, [:ptc_manager, key, value])

    for app <- [:logger, :phoenix, :phoenix_live_view],
        {key, value} <- Application.get_all_env(app),
        do: :peer.call(peer, Application, :put_env, [app, key, value])

    :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :critical])
    :ok = :peer.call(peer, PtcManager.ClusterMember, :migrate, [], 60_000)

    {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:ptc_manager], 60_000)
    {peer, database}
  end

  defp call(peer, module, function, args \\ []),
    do: :peer.call(peer, module, function, args, 30_000)

  defp poll(peer), do: call(peer, PeerPoller, :poll_now, [PeerPoller, 30_000])

  defp onboard(peer, root, id, owner, name) do
    checkout = Path.join(root, "#{id}-#{owner}-#{name}")
    File.mkdir_p!(checkout)

    {:ok, repository} =
      call(peer, Operations, :create_repository, [
        %{
          github_owner: owner,
          github_name: name,
          default_branch: "main",
          local_path: checkout,
          workspace_setup_command: "./scripts/ptc/bootstrap",
          workspace_setup_timeout_minutes: 10
        }
      ])

    commit_identity(peer)
    repository
  end

  defp commit_identity(peer) do
    call(peer, PtcManager.Repo, :insert, [
      %PtcManager.Operations.CommitIdentity{
        owner: "",
        name: "Test Agent",
        email: "agent@example.test"
      },
      [on_conflict: :nothing]
    ])
  end

  defp enable(peer, repository),
    do: call(peer, Operations, :set_repository_enabled, [repository.id, true, "maintainer"])

  defp disable(peer, repository),
    do: call(peer, Operations, :set_repository_enabled, [repository.id, false, "maintainer"])

  defp reload(peer, repository),
    do: call(peer, PtcManager.Repo, :get!, [Repository, repository.id])

  defp two_members(root) do
    ports = %{"alpha" => free_port(), "beta" => free_port()}
    map = members(ports)
    {a, a_db} = start_member(root, "alpha", ports["alpha"], map)
    {b, _b_db} = start_member(root, "beta", ports["beta"], map)
    poll(a)
    poll(b)
    %{a: a, b: b, ports: ports, map: map, a_db: a_db}
  end

  ## Scenarios

  test "1. members see each other healthy, and the Cluster page data agrees", %{root: root} do
    %{a: a, b: b} = two_members(root)
    homed = onboard(a, root, "alpha", "acme", "homed")
    assert {:ok, _repository} = enable(a, homed)
    poll(a)
    poll(b)

    assert call(a, PeerPoller, :current).members["beta"].health == "healthy"
    assert call(b, PeerPoller, :current).members["alpha"].health == "healthy"
    assert call(a, PeerPoller, :current).startup_complete?

    beta_seen_by_alpha = call(a, PeerPoller, :current).members["beta"].status
    beta_itself = call(b, PtcManager.Cluster.Status, :build)

    for field <- ~w(machine_id membership_revision protocol_version) do
      assert beta_seen_by_alpha[field] == beta_itself[field]
    end

    # What each member's Cluster page is built from: its own document first,
    # then every peer as its poller saw it.
    for {peer, other} <- [{a, "beta"}, {b, "alpha"}] do
      machines =
        [
          %{
            id: "self",
            health: "this machine",
            status: call(peer, PtcManager.Cluster.Status, :build)
          }
        ] ++
          (call(peer, PeerPoller, :current).members |> Map.values())

      assert Enum.find(machines, &(&1.id == other)).health == "healthy"

      overview = call(peer, PtcManager.Cluster.Overview, :build, [machines])
      assert [%{key: "acme/homed", homes: [home]}] = overview.repositories
      assert home in ["self", "alpha"]
      assert overview.drift == []
    end
  end

  test "2. a claim is refused while another member claims, and a move carries settings", %{
    root: root
  } do
    %{a: a, b: b} = two_members(root)

    on_a = onboard(a, root, "alpha", "acme", "api")

    {:ok, on_a} =
      call(a, Operations, :update_machine_requirements, [on_a.id, %{"tools" => []}, "maintainer"])

    call(a, PtcManager.AgentEnvironmentVariables, :put, [
      on_a.id,
      %{"name" => "API_TOKEN", "value" => "s3cr3t"},
      "maintainer"
    ])

    call(a, PtcManager.Repo, :update!, [Repository.changeset(on_a, %{auto_fix_daily_limit: 9})])
    assert {:ok, %Repository{enabled: true}} = enable(a, on_a)

    on_b = onboard(b, root, "beta", "acme", "api")
    refute on_b.enabled
    assert {:error, {:claim_refused, :claim_refused, checks}} = enable(b, on_b)
    assert [%{"machine_id" => "alpha", "result" => "claimed"}] = checks

    assert {:ok, _disabled} = disable(a, on_a)
    poll(b)

    assert {:ok, %{document: document, diff: diff}} = call(b, Move, :preview, [on_b, "alpha"])
    assert document["agent_environment_variable_names"] == ["API_TOKEN"]
    refute :erlang.term_to_binary(document) =~ "s3cr3t"
    assert diff.variables_to_enter == ["API_TOKEN"]

    assert {:ok, claimed, _checks} =
             call(b, Move, :claim, [on_b.id, "alpha", document["digest"], "maintainer"])

    assert claimed.enabled
    assert reload(b, on_b).auto_fix_daily_limit == 9
    refute reload(a, on_a).enabled
  end

  test "3. simultaneous claims never both succeed", %{root: root} do
    %{a: a, b: b} = two_members(root)

    for round <- 1..5 do
      name = "race-#{round}"
      on_a = onboard(a, root, "alpha", "acme", name)
      on_b = onboard(b, root, "beta", "acme", name)

      results =
        [{a, on_a}, {b, on_b}]
        |> Enum.map(fn {peer, repository} ->
          Task.async(fn ->
            Process.sleep(:rand.uniform(30))
            enable(peer, repository)
          end)
        end)
        |> Task.await_many(60_000)

      winners = Enum.count(results, &match?({:ok, _repository}, &1))
      assert winners <= 1, "both members claimed #{name}: #{inspect(results)}"
      refute reload(a, on_a).enabled and reload(b, on_b).enabled
    end
  end

  test "4. a partitioned member is unreachable, its peer keeps serving and refuses claims", %{
    root: root
  } do
    %{a: a, b: b} = two_members(root)
    own = onboard(a, root, "alpha", "acme", "own")
    assert {:ok, own} = enable(a, own)

    :ok = call(b, Supervisor, :terminate_child, [PtcManager.Supervisor, PtcManagerWeb.Endpoint])
    Process.sleep(1_200)
    poll(a)

    assert call(a, PeerPoller, :current).members["beta"].health == "unreachable"
    assert call(a, Gate, :check, [own]) == :ok

    other = onboard(a, root, "alpha", "acme", "other")

    assert {:error, {:claim_refused, :claim_refused, [%{"result" => "unreachable"}]}} =
             enable(a, other)
  end

  test "5. a member restarted from a stale database admits nothing for a moved repository", %{
    root: root
  } do
    %{a: a, b: b, ports: ports, map: map} = two_members(root)

    on_a = onboard(a, root, "alpha", "acme", "moved")
    assert {:ok, on_a} = enable(a, on_a)

    stale = Path.join(root, "alpha-stale.db")
    {:ok, _} = call(a, Ecto.Adapters.SQL, :query, [PtcManager.Repo, "VACUUM INTO ?", [stale]])

    assert {:ok, _} = disable(a, on_a)
    on_b = onboard(b, root, "beta", "acme", "moved")
    poll(b)
    assert {:ok, %{document: document}} = call(b, Move, :preview, [on_b, "alpha"])

    assert {:ok, _claimed, _checks} =
             call(b, Move, :claim, [on_b.id, "alpha", document["digest"], "maintainer"])

    :peer.stop(a)
    {a, _db} = start_member(root, "alpha", ports["alpha"], map, database: stale)
    restored = reload(a, on_a)
    assert restored.enabled

    assert call(a, Fence, :admission, [restored]) == {:error, :cluster_startup}
    poll(a)

    cluster = call(a, PeerPoller, :current)
    assert cluster.conflicts == ["acme/moved"]
    refute cluster.startup_complete?
    assert call(a, Gate, :check, [restored]) == {:error, :cluster_fenced}
    assert call(a, Fence, :console_banner) =~ "Waiting to hear from every member"
  end

  test "6. a member at another protocol version is incompatible and blocks claims", %{root: root} do
    ports = %{"alpha" => free_port(), "beta" => free_port()}
    map = members(ports)
    {a, _} = start_member(root, "alpha", ports["alpha"], map)
    {_b, _} = start_member(root, "beta", ports["beta"], map, cluster_protocol_version: 2)
    poll(a)

    assert call(a, PeerPoller, :current).members["beta"].health == "incompatible"

    repository = onboard(a, root, "alpha", "acme", "skewed")

    assert {:error, {:claim_refused, :claim_refused, [%{"result" => "incompatible"}]}} =
             enable(a, repository)
  end

  test "7. a machine removed from the others' map gets their signed refusal and fences itself", %{
    root: root
  } do
    ports = %{"alpha" => free_port(), "beta" => free_port(), "gamma" => free_port()}
    old_map = members(ports)
    new_map = Map.delete(old_map, "gamma")

    {a, _} = start_member(root, "alpha", ports["alpha"], new_map)
    {_b, _} = start_member(root, "beta", ports["beta"], new_map)
    {c, _} = start_member(root, "gamma", ports["gamma"], old_map)
    poll(a)
    poll(c)

    cluster = call(c, PeerPoller, :current)
    assert Enum.sort(cluster.refused_by) == ["alpha", "beta"]

    repository = onboard(c, root, "gamma", "acme", "orphan")
    call(c, PtcManager.Repo, :update!, [Repository.changeset(repository, %{enabled: true})])
    assert call(c, Fence, :admission, [reload(c, repository)]) == {:error, :not_member}
    assert call(c, Fence, :console_banner) =~ "does not count this machine as a member"
    assert call(c, Claims, :key, [repository]) == "acme/orphan"
  end
end
