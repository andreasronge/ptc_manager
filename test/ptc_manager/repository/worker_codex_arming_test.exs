defmodule PtcManager.Repository.WorkerCodexArmingTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorkerCodexArming

  defmodule ArmingCommand do
    def arming_command(args) do
      send(Application.fetch_env!(:ptc_manager, :worker_codex_arming_test_pid), {:arming, args})
      Application.get_env(:ptc_manager, :worker_codex_arming_test_result, {"", 0})
    end
  end

  setup do
    keys = [
      :herdr_run_as_user,
      :worker_codex_arming_command,
      :worker_codex_arming_test_pid,
      :worker_codex_arming_test_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")
    Application.put_env(:ptc_manager, :worker_codex_arming_command, ArmingCommand)
    Application.put_env(:ptc_manager, :worker_codex_arming_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    :ok
  end

  test "arms the worker configuration before a Codex agent starts" do
    assert :ok = WorkerCodexArming.prepare("codex")
    assert_receive {:arming, ["arm"]}
  end

  test "other agent kinds need nothing" do
    assert :ok = WorkerCodexArming.prepare("claude")
    assert :ok = WorkerCodexArming.prepare("cursor")
    refute_receive {:arming, _args}
  end

  test "does nothing when Herdr runs as the coordinator" do
    Application.delete_env(:ptc_manager, :herdr_run_as_user)

    assert :ok = WorkerCodexArming.prepare("codex")
    refute_receive {:arming, _args}
  end

  test "a failing helper stops the agent start with its output" do
    Application.put_env(:ptc_manager, :worker_codex_arming_test_result, {"no such home\n", 2})

    assert {:error, {:worker_codex_arming_failed, 2, "no such home"}} =
             WorkerCodexArming.prepare("codex")
  end
end
