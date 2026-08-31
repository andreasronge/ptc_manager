defmodule PtcManagerWeb.MaintenanceMode do
  @moduledoc false

  import Phoenix.LiveView

  alias PtcManager.OperationalMode

  @read_only_events ["close_agent"]

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :maintenance_mode, :handle_event, &handle_event/3)}
  end

  defp handle_event(event, _params, socket) when event in @read_only_events,
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
    end
  end
end
