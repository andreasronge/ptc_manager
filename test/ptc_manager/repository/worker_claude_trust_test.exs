defmodule PtcManager.Repository.WorkerClaudeTrustTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorkerClaudeTrust

  defmodule TrustCommand do
    def trust_command(args) do
      send(Application.fetch_env!(:ptc_manager, :worker_claude_trust_test_pid), {:trust, args})
      Application.get_env(:ptc_manager, :worker_claude_trust_test_result, {"", 0})
    end
  end

  setup do
    keys = [
      :herdr_run_as_user,
      :planning_snapshot_root,
      :worktree_root,
      :worker_claude_trust_command,
      :worker_claude_trust_test_pid,
      :worker_claude_trust_test_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")
    Application.put_env(:ptc_manager, :planning_snapshot_root, "/managed/planning-snapshots")
    Application.put_env(:ptc_manager, :worktree_root, "/managed/worktrees")
    Application.put_env(:ptc_manager, :worker_claude_trust_command, TrustCommand)
    Application.put_env(:ptc_manager, :worker_claude_trust_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    :ok
  end

  test "trusts one exact managed snapshot for Claude and revokes it afterwards" do
    path = "/managed/planning-snapshots/ptc-manager-planning-a74-b5d9b142"

    assert :ok = WorkerClaudeTrust.prepare("claude", path)
    assert_receive {:trust, ["allow", ^path]}

    assert :ok = WorkerClaudeTrust.revoke(path)
    assert_receive {:trust, ["revoke", ^path]}
  end

  test "trusts a job worktree under the managed worktree root" do
    path = "/managed/worktrees/andreasronge-ptc_manager-job-29-f1"

    assert {:ok, :trusted} = WorkerClaudeTrust.allow(path)
    assert_receive {:trust, ["allow", ^path]}
  end

  test "other agent kinds and unmanaged paths need nothing" do
    assert :ok = WorkerClaudeTrust.prepare("codex", "/managed/worktrees/job")
    assert :ok = WorkerClaudeTrust.prepare("cursor", "/managed/worktrees/job")
    assert {:ok, :not_required} = WorkerClaudeTrust.allow("/other/repository")
    assert {:ok, :not_required} = WorkerClaudeTrust.allow("/managed/worktrees/nested/deeper")
    assert :ok = WorkerClaudeTrust.revoke("/other/repository")
    refute_receive {:trust, _args}
  end

  test "does nothing when Herdr runs as the coordinator" do
    Application.delete_env(:ptc_manager, :herdr_run_as_user)

    assert :ok = WorkerClaudeTrust.prepare("claude", "/managed/worktrees/job")
    refute_receive {:trust, _args}
  end

  test "a failing helper stops the agent start with its output" do
    Application.put_env(:ptc_manager, :worker_claude_trust_test_result, {"no such home\n", 2})

    assert {:error, {:worker_claude_trust_failed, 2, "no such home"}} =
             WorkerClaudeTrust.prepare("claude", "/managed/worktrees/job")
  end
end
