defmodule PtcManager.Repository.WorkerHelperTest do
  use ExUnit.Case, async: false
  alias PtcManager.Repository.WorkerHelper

  test "same-account hosts execute helpers directly with scrubbed credentials" do
    previous = Application.get_env(:ptc_manager, :herdr_run_as_user)
    previous_secret = System.get_env("PTC_MANAGER_PASSWORD")

    on_exit(fn ->
      Application.put_env(:ptc_manager, :herdr_run_as_user, previous)

      if previous_secret,
        do: System.put_env("PTC_MANAGER_PASSWORD", previous_secret),
        else: System.delete_env("PTC_MANAGER_PASSWORD")
    end)

    Application.put_env(:ptc_manager, :herdr_run_as_user, nil)
    System.put_env("PTC_MANAGER_PASSWORD", "must-not-reach-helper")

    assert {"missing", 0} =
             WorkerHelper.run("/bin/sh", ["-c", "printf '%s' \"${PTC_MANAGER_PASSWORD-missing}\""])
  end
end
