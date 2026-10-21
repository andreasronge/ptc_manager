defmodule PtcManagerWeb.ClusterClaimLive do
  @moduledoc """
  Claims a repository that another member has given up, copying its settings.

  The repository must already be onboarded here, disabled, the ordinary way.
  The page checks that this machine is ready, fetches the source's settings,
  shows what they change and which secret variable names to re-enter, and
  claims with one confirmation.
  """

  use PtcManagerWeb, :live_view

  alias PtcManager.{Cluster, Operations}
  alias PtcManager.Cluster.{Claims, Move}
  alias PtcManagerWeb.ClusterDisplay

  @impl true
  def mount(%{"owner" => owner, "name" => name} = params, session, socket) do
    key = Claims.key(owner, name)
    repository = Enum.find(Operations.list_repositories(), &(Claims.key(&1) == key))
    source = params["from"]

    socket =
      socket
      |> assign(
        page_title: "Claim #{owner}/#{name}",
        actor: session["actor"] || "maintainer",
        key: key,
        source: source,
        repository: repository,
        readiness: repository && Move.readiness(repository),
        preview: nil,
        preview_error: nil
      )

    if connected?(socket) and claimable?(socket.assigns),
      do: {:ok, start_preview(socket)},
      else: {:ok, socket}
  end

  defp claimable?(assigns) do
    Cluster.enabled?() and assigns.repository != nil and not assigns.repository.enabled and
      is_binary(assigns.source) and Cluster.member?(assigns.source) and
      assigns.source != PtcManager.Machine.id()
  end

  # The source is asked outside the LiveView process's own work, so a slow
  # member never blocks the page.
  defp start_preview(socket) do
    repository = socket.assigns.repository
    source = socket.assigns.source
    start_async(socket, :preview, fn -> Move.preview(repository, source) end)
  end

  @impl true
  def handle_async(:preview, {:ok, {:ok, preview}}, socket),
    do: {:noreply, assign(socket, preview: preview, preview_error: nil)}

  def handle_async(:preview, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, preview_error: inspect(reason))}

  def handle_async(:preview, {:exit, reason}, socket),
    do: {:noreply, assign(socket, preview_error: inspect(reason))}

  @impl true
  def handle_event("refresh-preview", _params, socket) do
    if claimable?(socket.assigns), do: {:noreply, start_preview(socket)}, else: {:noreply, socket}
  end

  def handle_event("claim", %{"digest" => digest}, socket) do
    repository = socket.assigns.repository

    case Move.claim(repository.id, socket.assigns.source, digest, socket.assigns.actor) do
      {:ok, claimed, _checks} ->
        Operations.notify_changed(Operations)

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{socket.assigns.key} is homed here now. Its automations are paused; review them, then re-enter the listed variables."
         )
         |> push_navigate(to: ~p"/configuration/repositories/#{claimed.id}")}

      {:error, :settings_changed, _checks} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "The settings changed on #{socket.assigns.source}. Review them again."
         )
         |> start_preview()}

      {:error, :target_not_ready, _checks} ->
        {:noreply,
         put_flash(socket, :error, "This machine is not ready to run the repository yet.")}

      {:error, reason, checks} ->
        {:noreply, put_flash(socket, :error, ClusterDisplay.claim_refusal(reason, checks))}
    end
  end

  def field_label(field), do: field |> Atom.to_string() |> String.replace("_", " ")

  def value_text(nil), do: "unset"
  def value_text(value) when is_binary(value), do: value
  def value_text(value), do: Jason.encode!(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/cluster" switch_to="/cluster">
      <section>
        <p class="text-xs font-semibold uppercase tracking-wide text-slate-500">Move a repository</p>
        <h1 class="mt-2 text-2xl font-semibold">
          Claim {@key}<span :if={@source}> from {@source}</span>
        </h1>
      </section>

      <p :if={!PtcManager.Cluster.enabled?()} class="mt-6 text-sm text-slate-400">
        This console is not part of a cluster.
      </p>

      <p
        :if={PtcManager.Cluster.enabled?() && is_nil(@repository)}
        id="claim-not-onboarded"
        class="mt-6 text-sm text-amber-200"
      >
        {@key} is not configured on this machine. Onboard it on the
        <.link navigate={~p"/configuration"} class="text-teal-300">Configuration</.link>
        page first; it is added disabled, then come back here.
      </p>

      <p
        :if={@repository && @repository.enabled}
        id="claim-already-home"
        class="mt-6 text-sm text-slate-300"
      >
        {@key} is already homed on this machine.
      </p>

      <section
        :if={@readiness}
        id="claim-readiness"
        class="mt-6 rounded-2xl border border-white/10 bg-slate-900/70 p-5"
      >
        <h2 class="text-lg font-semibold">Is this machine ready?</h2>
        <ul class="mt-3 space-y-1 text-sm">
          <li
            :for={check <- @readiness}
            class={if check.ok?, do: "text-teal-200", else: "text-amber-200"}
          >
            {if check.ok?, do: "✓", else: "✗"} {check.check}
            <span :if={check.detail} class="ml-2 font-mono text-xs text-slate-500">
              {check.detail}
            </span>
          </li>
        </ul>
      </section>

      <p :if={@preview_error} id="claim-preview-error" class="mt-6 text-sm text-amber-200">
        The settings could not be fetched from {@source}: {@preview_error}. It must have disabled the repository with no work left.
        <button type="button" phx-click="refresh-preview" class="ml-2 text-teal-300">
          Try again
        </button>
      </p>

      <section :if={@preview} id="claim-preview" class="mt-6 space-y-6">
        <div class="rounded-2xl border border-white/10 bg-slate-900/70 p-5">
          <h2 class="text-lg font-semibold">Settings that change</h2>
          <p :if={@preview.diff.settings == []} class="mt-2 text-sm text-slate-400">None.</p>
          <table :if={@preview.diff.settings != []} class="mt-3 w-full text-left text-xs">
            <thead class="text-slate-500">
              <tr>
                <th class="py-1 pr-4">Setting</th>
                <th class="py-1 pr-4">Here now</th>
                <th class="py-1">From {@source}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={change <- @preview.diff.settings} id={"claim-setting-#{change.field}"}>
                <td class="py-1 pr-4 text-slate-300">{field_label(change.field)}</td>
                <td class="py-1 pr-4 font-mono text-slate-500">{value_text(change.current)}</td>
                <td class="py-1 font-mono text-slate-200">{value_text(change.incoming)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="rounded-2xl border border-white/10 bg-slate-900/70 p-5">
          <h2 class="text-lg font-semibold">Automations</h2>
          <p class="mt-1 text-xs text-slate-500">
            Each arrives paused, with its triggers, until you review it.
          </p>
          <ul class="mt-3 space-y-1 text-sm">
            <li
              :for={automation <- @preview.diff.automations}
              id={"claim-automation-#{automation.key}"}
            >
              <span class="text-slate-200">{automation.name}</span>
              <span class="ml-2 text-xs text-slate-500">
                {if automation.action == "update",
                  do: "new version of the existing automation",
                  else: "created"} · {automation.triggers} triggers
              </span>
            </li>
          </ul>
        </div>

        <div class="rounded-2xl border border-white/10 bg-slate-900/70 p-5">
          <h2 class="text-lg font-semibold">Agent environment variables</h2>
          <p class="mt-1 text-xs text-slate-500">
            Secret values never leave {@source}. Re-enter these on this machine.
          </p>
          <p :if={@preview.diff.variables_to_enter == []} class="mt-2 text-sm text-slate-400">
            Nothing to re-enter.
          </p>
          <ul id="claim-variables" class="mt-2 font-mono text-sm text-amber-200">
            <li :for={name <- @preview.diff.variables_to_enter}>{name}</li>
          </ul>
        </div>

        <button
          id="confirm-claim"
          type="button"
          phx-click="claim"
          phx-value-digest={@preview.document["digest"]}
          disabled={!Enum.all?(@readiness, & &1.ok?)}
          data-confirm={"Claim #{@key} on this machine with these settings?"}
          class="rounded-lg bg-teal-400 px-4 py-2 text-sm font-semibold text-slate-950 hover:bg-teal-300 disabled:opacity-50"
        >
          Claim {@key} here
        </button>
      </section>
    </Layouts.app>
    """
  end
end
