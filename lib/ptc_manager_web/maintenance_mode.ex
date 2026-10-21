defmodule PtcManagerWeb.MaintenanceMode do
  @moduledoc false

  import Phoenix.LiveView

  alias PtcManager.OperationalMode

  @read_only_events ["close_agent", "recheck-readiness"]
  # The one mutation a restricted console must accept: the Deployments page's
  # Activate, which runs the canary and ends the restriction. Its handler
  # decides on its own whether activation is available.
  @recovery_events ["activate"]
  # A fenced expensive operation is released by a maintainer even while the
  # console is restricted; releasing it starts no work.
  @operation_release_events ["inspect-release", "close-release", "release-operation"]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :maintenance_mode, :handle_event, &handle_event/3)}
  end

  defp handle_event(event, _params, socket) when event in @read_only_events,
    do: {:cont, socket}

  defp handle_event(event, _params, %{view: PtcManagerWeb.DeploymentsLive} = socket)
       when event in @recovery_events,
       do: {:cont, socket}

  defp handle_event(event, _params, %{view: PtcManagerWeb.OperationsLive} = socket)
       when event in @operation_release_events,
       do: {:cont, socket}

  defp handle_event(_event, _params, socket) do
    case OperationalMode.authorize_ordinary_work() do
      :ok ->
        {:cont, socket}

      {:error, :maintenance_mode} ->
        {:halt,
         put_flash(
           socket,
           :error,
           "PtcManager is in maintenance mode. Read-only pages remain available, but new work is paused."
         )}

      {:error, :deployment_draining} ->
        {:halt,
         put_flash(
           socket,
           :error,
           "PtcManager is waiting to deploy. Existing work may finish, but new work is paused."
         )}
    end
  end
end
