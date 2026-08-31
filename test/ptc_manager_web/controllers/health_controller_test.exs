defmodule PtcManagerWeb.HealthControllerTest do
  use PtcManagerWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:ptc_manager, :operational_mode)
    on_exit(fn -> restore_env(:operational_mode, previous) end)
    :ok
  end

  test "reports health and maintenance mode without authentication", %{conn: conn} do
    Application.put_env(:ptc_manager, :operational_mode, :maintenance)

    assert %{"status" => "ok", "operational_mode" => "maintenance"} =
             conn
             |> get(~p"/health")
             |> json_response(200)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
