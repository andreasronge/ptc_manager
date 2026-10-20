defmodule PtcManagerWeb.ClusterLive do
  @moduledoc """
  Every member of the cluster as this console sees it: health, revision,
  protocol, and which member claims each repository. Peer data comes from the
  poller's memory; this member's own rows are read directly.
  """

  use PtcManagerWeb, :live_view

  alias PtcManager.{Cluster, Machine, Operations}
  alias PtcManager.Cluster.{PeerPoller, Status}
  alias PtcManagerWeb.ClusterDisplay

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PeerPoller.subscribe()
      Operations.subscribe()
    end

    {:ok, socket |> assign(:page_title, "Cluster") |> load()}
  end

  @impl true
  def handle_info({:cluster_status, _cluster}, socket), do: {:noreply, load(socket)}
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("poll-now", _params, socket) do
    if Cluster.enabled?(), do: PeerPoller.poll_now()
    {:noreply, load(socket)}
  end

  defp load(socket) do
    cluster = PeerPoller.current()
    local = if Cluster.enabled?(), do: Status.build(), else: nil
    now = DateTime.utc_now()

    machines =
      [
        %{
          id: Machine.id(),
          health: "this machine",
          status: local,
          error: nil,
          last_success_at: now
        }
      ] ++
        (cluster.members |> Map.values() |> Enum.sort_by(& &1.id))

    assign(socket,
      enabled?: Cluster.enabled?(),
      now: now,
      cluster: cluster,
      machines: machines,
      repositories: repositories(machines),
      membership_revision: Cluster.enabled?() && Cluster.membership_revision()
    )
  end

  # One row per repository any member knows, with each member's claim.
  defp repositories(machines) do
    machines
    |> Enum.flat_map(fn machine ->
      for repository <- List.wrap(machine.status && machine.status["repositories"]),
          do: {repository["repository"], machine.id, repository}
    end)
    |> Enum.group_by(fn {key, _id, _repository} -> key end, fn {_key, id, repository} ->
      {id, repository}
    end)
    |> Enum.map(fn {key, entries} ->
      claims = Map.new(entries)

      %{
        key: key,
        claims: claims,
        homes: for({id, %{"claim" => claim}} <- claims, claim not in [nil, "none"], do: id)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  def short_sha(nil), do: "unknown"
  def short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  def machine_name(%{status: %{"machine_name" => name}}) when is_binary(name), do: name
  def machine_name(%{id: id}), do: id

  def deployments_url(id), do: Cluster.console_url(id, "/deployments")

  def claim_text(nil), do: "not configured"
  def claim_text(%{"claim" => "enabled"}), do: "enabled"
  def claim_text(%{"claim" => "live_work"}), do: "disabled, work remains"
  def claim_text(%{"claim" => "pending"}), do: "claim in progress"
  def claim_text(%{"claim" => "none"}), do: "disabled"
  def claim_text(%{"claim" => other}), do: other

  def blockers(%{"claim_blockers" => blockers}) when is_list(blockers),
    do: Enum.join(blockers, ", ")

  def blockers(_repository), do: ""

  defdelegate health_class(health), to: ClusterDisplay

  def key_parts(key), do: String.split(key, "/", parts: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/cluster">
      <section class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Cluster</h1>
          <p class="mt-1 max-w-3xl text-sm text-slate-400">
            Each repository is homed on one machine, which polls GitHub for it and runs all its work. Members read each other's status over signed requests and never command each other.
          </p>
        </div>
        <button
          :if={@enabled?}
          id="poll-members"
          type="button"
          phx-click="poll-now"
          class="rounded-lg border border-white/10 px-3 py-1.5 text-xs font-semibold text-slate-200 hover:bg-white/5"
        >
          Ask every member now
        </button>
      </section>

      <p :if={!@enabled?} id="cluster-disabled" class="mt-8 text-sm text-slate-400">
        This console is not part of a cluster. Set <code>PTC_CLUSTER_MEMBERS</code>
        and <code>PTC_CLUSTER_SECRET</code>
        to join several machines; the README's "Several machines" section explains how.
      </p>

      <section :if={@enabled?} id="cluster-machines" class="mt-8">
        <h2 class="text-lg font-semibold">Machines</h2>
        <p class="mt-1 text-xs text-slate-500">
          Membership revision <span class="font-mono">{short_sha(@membership_revision)}</span>
        </p>
        <div class="mt-4 grid gap-4 lg:grid-cols-2">
          <article
            :for={machine <- @machines}
            id={"machine-#{machine.id}"}
            class="rounded-2xl border border-white/10 bg-slate-900/70 p-5"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="flex items-center gap-2 text-base font-semibold">
                  <span class={["size-2 rounded-full", health_class(machine.health)]}></span>
                  {machine_name(machine)}
                </p>
                <p class="mt-1 font-mono text-xs text-slate-500">{machine.id}</p>
              </div>
              <span class="text-xs text-slate-400">{machine.health}</span>
            </div>
            <dl class="mt-4 grid grid-cols-2 gap-x-4 gap-y-2 text-xs">
              <dt class="text-slate-500">Deployed</dt>
              <dd class="font-mono text-slate-300">
                {short_sha(machine.status && machine.status["deployed_sha"])}
              </dd>
              <dt class="text-slate-500">Protocol</dt>
              <dd class="text-slate-300">{machine.status && machine.status["protocol_version"]}</dd>
              <dt class="text-slate-500">Mode</dt>
              <dd class="text-slate-300">{machine.status && machine.status["operational_mode"]}</dd>
              <dt class="text-slate-500">Last heard</dt>
              <dd class="text-slate-300">
                {(machine.last_success_at && TimeFormat.relative(@now, machine.last_success_at)) ||
                  "never"}
              </dd>
            </dl>
            <p :if={machine.error} class="mt-3 text-xs text-amber-300">{machine.error}</p>
            <a
              href={deployments_url(machine.id)}
              class="mt-4 inline-block text-xs font-semibold text-teal-300 hover:text-teal-200"
            >
              Deployments on this machine
            </a>
          </article>
        </div>
      </section>

      <section :if={@enabled?} id="cluster-repositories" class="mt-10">
        <h2 class="text-lg font-semibold">Repositories</h2>
        <div class="mt-4 overflow-x-auto">
          <table class="w-full min-w-[36rem] text-left text-sm">
            <thead class="text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th class="py-2 pr-4">Repository</th>
                <th class="py-2 pr-4">Home</th>
                <th :for={machine <- @machines} class="py-2 pr-4">{machine_name(machine)}</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-white/5">
              <tr :for={repository <- @repositories} id={"cluster-repository-#{repository.key}"}>
                <td class="py-2 pr-4 font-mono text-xs text-slate-200">{repository.key}</td>
                <td class="py-2 pr-4 text-xs">
                  <span :if={repository.homes == []} class="text-slate-500">unclaimed</span>
                  <span
                    :if={length(repository.homes) > 1}
                    class="font-semibold text-rose-300"
                  >
                    conflict: {Enum.join(repository.homes, ", ")}
                  </span>
                  <span :if={length(repository.homes) == 1} class="text-slate-200">
                    {hd(repository.homes)}
                  </span>
                </td>
                <td :for={machine <- @machines} class="py-2 pr-4 text-xs text-slate-400">
                  {claim_text(repository.claims[machine.id])}
                  <span class="block text-[11px] text-slate-500">
                    {blockers(repository.claims[machine.id] || %{})}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
