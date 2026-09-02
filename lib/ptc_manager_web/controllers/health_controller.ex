defmodule PtcManagerWeb.HealthController do
  use PtcManagerWeb, :controller

  alias PtcManager.OperationalMode

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      operational_mode: mode_name(OperationalMode.mode())
    })
  end

  defp mode_name(:active), do: "active"
  defp mode_name(:draining), do: "draining"
  defp mode_name(:maintenance), do: "maintenance"
  defp mode_name({:canary, _invocation_id}), do: "canary"
end
