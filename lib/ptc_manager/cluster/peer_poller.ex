defmodule PtcManager.Cluster.PeerPoller do
  @moduledoc """
  Polls every other member's status every 15 seconds and keeps what it learns
  in memory: each member's health and last document, and the fences that keep
  this member from admitting work it might not own.

  - **Health.** A member is `healthy` when it answers with a signed document at
    this protocol version and membership revision, `incompatible` when it
    answers at another, `refused` when it answers that this machine is not a
    member, and `unreachable` after 60 seconds without a signed answer.
  - **Startup.** After a boot nothing is admitted until one round has heard
    from every other member, healthy, with no conflicting claim. There is no
    timeout fallback: a member that did not restart keeps serving through a
    partition, and one that did waits to be sure.
  - **Conflict.** A repository this member claims that a peer also claims
    stops admitting new work here until a person resolves it on one side.
  - **Non-member.** A peer's signed refusal stops all admission here.

  Only transitions are written, as audit events; claim checks always fetch
  fresh documents rather than trusting this cache.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias PtcManager.{Cluster, Repo}
  alias PtcManager.Cluster.{Claims, Peer}
  alias PtcManager.Operations.{AuditEvent, Repository}

  @table __MODULE__
  @topic "cluster"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def subscribe, do: Phoenix.PubSub.subscribe(PtcManager.PubSub, @topic)

  @doc """
  The cluster as this member sees it: `%{members: %{id => member}, startup_complete?:
  boolean, conflicts: [key], refused_by: [id], polled_at: DateTime | nil}`.
  """
  def current do
    case :ets.whereis(@table) do
      :undefined -> initial()
      table -> lookup(table)
    end
  end

  defp lookup(table) do
    case :ets.lookup(table, :cluster) do
      [{:cluster, cluster}] -> cluster
      [] -> initial()
    end
  rescue
    ArgumentError -> initial()
  end

  defp initial do
    %{
      members:
        Map.new(Cluster.peers(), fn {id, url} ->
          {id,
           %{
             id: id,
             base_url: url,
             health: "unknown",
             status: nil,
             error: nil,
             last_success_at: nil,
             last_attempt_at: nil
           }}
        end),
      startup_complete?: not Cluster.enabled?(),
      conflicts: [],
      refused_by: [],
      polled_at: nil
    }
  end

  @doc false
  # Tests set what the poller would have learned.
  def put(cluster, server \\ __MODULE__), do: GenServer.call(server, {:put, cluster})

  @doc false
  def reset(server \\ __MODULE__), do: GenServer.call(server, {:put, initial()})

  @doc "Runs one polling round now and waits for it (tests, and Refresh)."
  def poll_now(server \\ __MODULE__, timeout \\ 30_000),
    do: GenServer.call(server, :poll, timeout)

  ## Server

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    :ets.insert(@table, {:cluster, initial()})

    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:ptc_manager, :cluster_poll_interval_ms, 15_000)
      )

    state = %{
      interval_ms: interval_ms,
      started_at: System.monotonic_time(:millisecond),
      peer_opts: Keyword.get(opts, :peer_opts, [])
    }

    if Cluster.enabled?() and interval_ms > 0, do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call({:put, cluster}, _from, state) do
    :ets.insert(@table, {:cluster, Map.merge(initial(), cluster)})
    {:reply, :ok, state}
  end

  def handle_call(:poll, _from, state) do
    {:reply, :ok, poll_round(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, poll_round(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp poll_round(state) do
    if Cluster.enabled?() do
      previous = current()
      now = DateTime.utc_now()

      results =
        Cluster.peers()
        |> Task.async_stream(fn {id, _url} -> {id, Peer.fetch_status(id, state.peer_opts)} end,
          timeout: 15_000,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.zip(Cluster.peers())
        |> Enum.map(fn
          {{:ok, result}, _peer} -> result
          {{:exit, reason}, {id, _url}} -> {id, {:error, {:poll_exit, reason}}}
        end)

      members =
        Map.new(results, fn {id, result} ->
          {id, member(Map.get(previous.members, id) || initial().members[id], result, now, state)}
        end)

      refused_by = for {id, %{health: "refused"}} <- members, do: id
      conflicts = conflicts(members)
      all_healthy? = Enum.all?(members, fn {_id, member} -> member.health == "healthy" end)

      cluster = %{
        members: members,
        startup_complete?: previous.startup_complete? or (all_healthy? and conflicts == []),
        conflicts: conflicts,
        refused_by: refused_by,
        polled_at: now
      }

      record_transitions(previous, cluster)
      :ets.insert(@table, {:cluster, cluster})
      Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:cluster_status, cluster})
    end

    state
  rescue
    error ->
      Logger.warning("cluster poll failed: #{Exception.message(error)}")
      state
  end

  defp member(member, {:ok, status}, now, _state) do
    compatible? =
      status["protocol_version"] == Cluster.protocol_version() and
        status["membership_revision"] == Cluster.membership_revision()

    %{
      member
      | health: if(compatible?, do: "healthy", else: "incompatible"),
        status: status,
        error: nil,
        last_success_at: now,
        last_attempt_at: now
    }
  end

  defp member(member, {:error, :not_a_member}, now, _state),
    do: %{
      member
      | health: "refused",
        error: "this machine is not in its member map",
        last_attempt_at: now
    }

  defp member(member, {:error, reason}, now, state) do
    since =
      case member.last_success_at do
        nil -> System.monotonic_time(:millisecond) - state.started_at
        at -> DateTime.diff(now, at, :millisecond)
      end

    # A signed refusal stands until the member answers again: a later
    # transport failure is no evidence that it now counts this machine in.
    health =
      cond do
        member.health == "refused" -> "refused"
        since >= unreachable_after_ms() -> "unreachable"
        member.health in ["healthy", "incompatible"] -> member.health
        true -> "unknown"
      end

    %{member | health: health, error: inspect(reason), last_attempt_at: now}
  end

  # A test build may shorten the bound for the integration tests; a release
  # always waits a minute.
  if Application.compile_env(:ptc_manager, :cluster_test_overrides, false) do
    defp unreachable_after_ms,
      do: Application.get_env(:ptc_manager, :cluster_unreachable_after_ms, 60_000)
  else
    defp unreachable_after_ms, do: 60_000
  end

  # A repository this member claims that a reachable peer also claims.
  defp conflicts(members) do
    repositories = Repo.all(from(repository in Repository))
    %{states: states} = Claims.snapshot(repositories)
    ours = for {key, state} <- states, state != "none", into: MapSet.new(), do: key

    members
    |> Enum.flat_map(fn {_id, member} ->
      for %{"repository" => key, "claim" => claim} <-
            List.wrap(member.status && member.status["repositories"]),
          claim not in [nil, "none"],
          MapSet.member?(ours, key),
          do: key
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp record_transitions(previous, cluster) do
    Enum.each(cluster.members, fn {id, member} ->
      old = previous.members[id]

      if old == nil or old.health != member.health do
        audit("cluster.member_health_changed", %{
          "member" => id,
          "old" => old && old.health,
          "new" => member.health,
          "error" => member.error
        })
      end
    end)

    if previous.conflicts != cluster.conflicts do
      audit("cluster.ownership_conflict_changed", %{
        "old" => previous.conflicts,
        "new" => cluster.conflicts
      })
    end

    if previous.startup_complete? != cluster.startup_complete? do
      audit("cluster.startup_fence_lifted", %{"members" => Map.keys(cluster.members)})
    end

    :ok
  end

  defp audit(action, details) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: "system",
      action: action,
      target_type: "machine",
      target_id: 0,
      details: Map.put(details, "machine_id", PtcManager.Machine.id())
    })
    |> Repo.insert()
  rescue
    error -> Logger.warning("cluster transition not recorded: #{Exception.message(error)}")
  end
end
