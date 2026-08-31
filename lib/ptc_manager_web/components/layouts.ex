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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100">
      <header class="sticky top-0 z-30 border-b border-white/10 bg-slate-950/90 px-4 backdrop-blur sm:px-6">
        <div class="mx-auto flex min-h-16 max-w-7xl flex-wrap items-center justify-between gap-x-6 gap-y-2 py-3 sm:flex-nowrap sm:py-0">
          <a href={~p"/"} class="flex items-center gap-3">
            <span class="grid size-9 place-items-center rounded-xl bg-teal-400 font-black text-slate-950">
              P
            </span>
            <span>
              <span class="block text-sm font-semibold leading-4">PtcManager</span>
              <span class="block text-xs text-slate-500">Maintainer console</span>
            </span>
          </a>
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
              active={@current_path == "/operations"}
              icon="hero-chart-bar-square-mini"
            >
              Operations
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

      <main class="px-4 py-7 sm:px-6 sm:py-10">
        <div class="mx-auto max-w-7xl">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
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
