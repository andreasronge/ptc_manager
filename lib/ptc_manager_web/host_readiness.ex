defmodule PtcManagerWeb.HostReadiness do
  @moduledoc false

  # The readiness banner is part of every page's layout. Pages pass
  # `@host_readiness`, the failing checks, kept current from readiness
  # broadcasts; the banner's Recheck evaluates the host again.

  import Phoenix.LiveView

  alias PtcManager.Machine.Readiness

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Readiness.subscribe()

    socket =
      socket
      |> Phoenix.Component.assign(:host_readiness, Readiness.failing())
      |> attach_hook(:host_readiness_path, :handle_params, &remember_path/3)
      |> attach_hook(:host_readiness, :handle_event, &handle_event/3)
      |> attach_hook(:host_readiness_report, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_info({:host_readiness, report}, socket),
    do: {:halt, Phoenix.Component.assign(socket, :host_readiness, Readiness.failing(report))}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp remember_path(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {:cont, Phoenix.Component.assign(socket, :host_readiness_path, path <> query_suffix(query))}
  end

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query

  defp handle_event("recheck-readiness", _params, socket) do
    message =
      case Readiness.failing(Readiness.recheck()) do
        [] -> "This host is ready."
        failing -> "Still failing: #{Enum.map_join(failing, ", ", & &1.key)}."
      end

    {:halt,
     socket
     |> put_flash(:info, message)
     |> push_navigate(to: socket.assigns[:host_readiness_path] || "/")}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end
