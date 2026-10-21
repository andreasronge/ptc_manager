defmodule PtcManagerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PtcManagerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_path, :string, default: "/"

  attr :switch_to, :any,
    default: nil,
    doc: "where the machine switcher lands on another member; a repository struct or a path"

  attr :repositories, :list, default: []
  attr :selected_repository, :string, default: nil

  attr :readiness, :list,
    default: [],
    doc: "failing host readiness checks (`PtcManager.Machine.Readiness`)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100">
      <header class="sticky top-0 z-30 border-b border-white/10 bg-slate-950/90 px-4 backdrop-blur sm:px-6">
        <div class="mx-auto flex min-h-16 max-w-7xl flex-wrap items-center justify-between gap-x-6 gap-y-2 py-3 sm:flex-nowrap sm:py-0">
          <div class="flex items-center gap-3">
            <a href={~p"/"} class="flex items-center gap-3">
              <span class="grid size-9 place-items-center rounded-xl bg-teal-400 font-black text-slate-950">
                P
              </span>
              <span>
                <span class="block text-sm font-semibold leading-4">PtcManager</span>
                <span class="block text-xs text-slate-500">Maintainer console</span>
              </span>
            </a>
            <.machine_badge machine={PtcManager.Machine.describe()} />
            <.machine_switcher
              :if={PtcManager.Cluster.enabled?()}
              current_path={@current_path}
              switch_to={@switch_to}
            />
          </div>
          <nav
            aria-label="Primary"
            class="order-3 flex w-full gap-1 overflow-x-auto sm:order-none sm:w-auto"
          >
            <.nav_link href={~p"/"} active={@current_path == "/"} icon="hero-inbox-stack-mini">
              Planning
            </.nav_link>
            <.nav_link
              href={~p"/board"}
              active={@current_path == "/board"}
              icon="hero-view-columns-mini"
            >
              Delivery
            </.nav_link>
            <.nav_link
              href={~p"/updates"}
              active={String.starts_with?(@current_path, "/updates")}
              icon="hero-newspaper-mini"
            >
              Updates
            </.nav_link>
            <.nav_link
              href={~p"/operations"}
              active={String.starts_with?(@current_path, "/operations")}
              icon="hero-chart-bar-square-mini"
            >
              Operations
            </.nav_link>
            <.nav_link
              href={~p"/automations"}
              active={String.starts_with?(@current_path, "/automations")}
              icon="hero-bolt-mini"
            >
              Automations
            </.nav_link>
            <.nav_link
              href={~p"/deployments"}
              active={@current_path == "/deployments"}
              icon="hero-rocket-launch-mini"
            >
              Deploy
            </.nav_link>
            <.nav_link
              :if={PtcManager.Cluster.enabled?()}
              href={~p"/cluster"}
              active={@current_path == "/cluster"}
              icon="hero-server-stack-mini"
            >
              Cluster
            </.nav_link>
            <.nav_link
              href={~p"/configuration"}
              active={@current_path == "/configuration"}
              icon="hero-cog-6-tooth-mini"
            >
              Configuration
            </.nav_link>
          </nav>
          <.link href={~p"/logout"} method="delete" class="text-sm text-slate-400 hover:text-white">
            Sign out
          </.link>
        </div>
      </header>

      <div
        :if={@repositories != []}
        id="repository-scope"
        class="border-b border-white/5 bg-slate-950/70 px-4 py-2 sm:px-6"
      >
        <div class="mx-auto flex max-w-7xl items-center justify-end gap-3">
          <label for="repository-selector" class="text-xs font-medium text-slate-500">
            Repository
          </label>
          <select
            id="repository-selector"
            data-repository-selector
            onchange="window.ptcSelectRepository(this.value)"
            class="max-w-[18rem] rounded-lg border border-white/10 bg-slate-900 px-3 py-1.5 text-sm text-slate-200"
          >
            <option value="all" selected={is_nil(@selected_repository)}>All repositories</option>
            <option
              :for={repository <- @repositories}
              value={repository_key(repository)}
              selected={@selected_repository == repository_key(repository)}
            >
              {repository.github_owner}/{repository.github_name}
            </option>
          </select>
        </div>
      </div>

      <div
        :if={PtcManager.Cluster.Fence.console_banner()}
        id="cluster-banner"
        role="status"
        class="border-b border-rose-400/20 bg-rose-400/[0.08] px-4 py-3 text-rose-100 sm:px-6"
      >
        <div class="mx-auto flex max-w-7xl items-start gap-3 text-sm">
          <.icon name="hero-server-stack-mini" class="mt-0.5 size-4 shrink-0" />
          <p>{PtcManager.Cluster.Fence.console_banner()}</p>
        </div>
      </div>

      <div
        :if={@readiness != []}
        id="readiness-banner"
        role="status"
        class="border-b border-rose-400/20 bg-rose-400/[0.08] px-4 py-3 text-rose-100 sm:px-6"
      >
        <div class="mx-auto flex max-w-7xl items-start gap-3 text-sm">
          <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-4 shrink-0" />
          <div class="min-w-0 flex-1">
            <p class="font-semibold">
              {if Enum.any?(@readiness, & &1.blocking),
                do: "This host is not ready; it admits no new work.",
                else: "Host readiness needs attention."}
            </p>
            <ul class="mt-1 space-y-0.5">
              <li :for={check <- @readiness} id={"readiness-#{check.key}"}>
                <span class="font-mono text-xs">{check.key}</span>: {check.sentence}
              </li>
            </ul>
          </div>
          <button
            id="recheck-readiness"
            type="button"
            phx-click="recheck-readiness"
            class="shrink-0 rounded-lg border border-rose-200/30 px-3 py-1 text-xs font-semibold hover:bg-rose-200/10"
          >
            Recheck
          </button>
        </div>
      </div>

      <div
        :if={PtcManager.OperationalMode.maintenance?()}
        id="maintenance-mode-banner"
        role="status"
        class="border-b border-amber-400/20 bg-amber-400/[0.08] px-4 py-3 text-amber-100 sm:px-6"
      >
        <div class="mx-auto flex max-w-7xl items-start gap-3 text-sm">
          <.icon name="hero-wrench-screwdriver-mini" class="mt-0.5 size-4 shrink-0" />
          <p>
            <span class="font-semibold">
              {PtcManager.OperationalMode.label(PtcManager.OperationalMode.mode())} mode.
            </span>
            {restricted_mode_message(PtcManager.OperationalMode.mode())}
          </p>
        </div>
      </div>

      <main class="px-4 py-7 sm:px-6 sm:py-10">
        <div class="mx-auto max-w-7xl">
          {render_slot(@inner_block)}
        </div>
      </main>

      <div
        id="action-feedback"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        phx-update="ignore"
      >
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  def repository_key(repository), do: "#{repository.github_owner}/#{repository.github_name}"

  defp restricted_mode_message(:draining),
    do: "New work is paused while existing agents finish and deployment waits for a safe window."

  defp restricted_mode_message(_mode),
    do:
      "Read-only inspection is available; agents, queues, synchronization, and configuration changes are paused."

  @doc """
  The machine this console runs on. Its colour comes from the machine id, so
  consoles of different machines are hard to mistake for each other.
  """
  attr :machine, :map, required: true

  def machine_badge(assigns) do
    ~H"""
    <span
      id="machine-badge"
      title={"Machine #{@machine.id} (#{@machine.os})"}
      class="inline-flex items-center gap-2 rounded-full border px-2.5 py-1 text-xs font-semibold"
      style={"border-color: hsl(#{@machine.hue} 70% 55% / 0.5); background-color: hsl(#{@machine.hue} 70% 55% / 0.12)"}
    >
      <span class="size-2 rounded-full" style={"background-color: hsl(#{@machine.hue} 70% 55%)"}>
      </span>
      <span class="text-slate-100">{@machine.name}</span>
      <span class="font-normal text-slate-400">{@machine.os}</span>
    </span>
    """
  end

  @doc """
  The other members, each with a health dot. Following one opens the same
  place on that member's console where record ids allow it.
  """
  attr :current_path, :string, required: true
  attr :switch_to, :any, default: nil

  def machine_switcher(assigns) do
    cluster = PtcManager.Cluster.PeerPoller.current()

    {path, repository} =
      case assigns.switch_to do
        %{github_owner: _owner} = repository -> {assigns.current_path, repository}
        path when is_binary(path) -> {path, nil}
        nil -> {assigns.current_path, nil}
      end

    assigns =
      assign(assigns,
        members:
          cluster.members
          |> Map.values()
          |> Enum.sort_by(& &1.id)
          |> Enum.map(fn member ->
            Map.put(
              member,
              :url,
              PtcManagerWeb.ClusterDisplay.switch_url(member.id, path, repository)
            )
          end)
      )

    ~H"""
    <details id="machine-switcher" class="relative">
      <summary class="cursor-pointer list-none rounded-lg px-2 py-1 text-xs text-slate-400 hover:bg-white/5 hover:text-white">
        Switch machine
      </summary>
      <div class="absolute left-0 z-40 mt-2 min-w-56 rounded-xl border border-white/10 bg-slate-900 p-2 shadow-xl">
        <a
          :for={member <- @members}
          id={"switch-to-#{member.id}"}
          href={member.url}
          class="flex items-center justify-between gap-3 rounded-lg px-3 py-2 text-sm text-slate-200 hover:bg-white/5"
        >
          <span class="flex items-center gap-2">
            <span class={[
              "size-2 rounded-full",
              PtcManagerWeb.ClusterDisplay.health_class(member.health)
            ]}>
            </span>
            {(member.status && member.status["machine_name"]) || member.id}
          </span>
          <span class="text-xs text-slate-500">{member.health}</span>
        </a>
      </div>
    </details>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "inline-flex shrink-0 items-center gap-2 rounded-lg px-3 py-2 text-sm font-medium transition",
        @active && "bg-white/10 text-white",
        !@active && "text-slate-400 hover:bg-white/5 hover:text-white"
      ]}
    >
      <.icon name={@icon} class="size-4" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <div id="action-feedback" role="status" aria-live="polite" aria-atomic="true" phx-update="ignore"></div>
      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
