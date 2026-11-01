defmodule PtcManager.TestHostEnvironment do
  @moduledoc "Isolates host configuration tests from the managed pane's environment."

  def cleared_environment do
    variables =
      Enum.map(PtcManager.Host.path_specs(), fn {_key, _app_key, variable, _kind} -> variable end)

    Enum.map(["PTC_MANAGED_OPERATION_CONTEXT" | variables], &{&1, nil})
  end

  # System environment is global; callers must use async: false.
  def without_host_environment(fun) do
    cleared = cleared_environment()
    previous = Enum.map(cleared, fn {key, _} -> {key, System.get_env(key)} end)

    try do
      System.put_env(cleared)
      fun.()
    after
      System.put_env(previous)
    end
  end
end
