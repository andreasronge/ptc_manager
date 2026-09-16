defmodule PtcManagerWeb.DeliveryReportLive do
  use PtcManagerWeb, :live_view
  alias PtcManager.DeliveryReport, as: Report

  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Delivery report", tab: "summary", job_id: String.to_integer(id))
     |> reload()}
  end

  def handle_event("tab", %{"tab" => tab}, socket)
      when tab in ~w(summary performance logbook coverage),
      do: {:noreply, assign(socket, :tab, tab)}

  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> reload() |> put_flash(:info, "Report refreshed.")}

  defp reload(socket), do: assign(socket, :report, Report.load(socket.assigns.job_id))
  defp value(nil), do: "Not recorded"
  defp value(v), do: to_string(v)
  defp detail(v) when is_binary(v), do: v
  defp detail(v), do: Jason.encode!(v, pretty: true)

  defp model(settings, role) do
    s = settings || %{}

    keys =
      if String.starts_with?(role, "Reviewer"),
        do: ~w(reviewer_kind reviewer_model reviewer_effort),
        else: ~w(kind model effort)

    Enum.map_join(keys, " / ", &value(s[&1]))
  end

  defp metrics(nil), do: []
  defp metrics(map), do: Enum.sort(map)
end
