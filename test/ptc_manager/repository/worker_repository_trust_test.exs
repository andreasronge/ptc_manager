defmodule PtcManager.Repository.WorkerRepositoryTrustTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorkerRepositoryTrust

  defmodule GitCommand do
    def git_command(args) do
      send(Application.fetch_env!(:ptc_manager, :worker_repository_trust_test_pid), {
        :git_command,
        args
      })

      {"", 0}
    end
  end

  setup do
    previous =
      for key <- [
            :herdr_run_as_user,
            :planning_snapshot_root,
            :worker_repository_trust_command,
            :worker_repository_trust_test_pid
          ],
          into: %{},
          do: {key, Application.get_env(:ptc_manager, key)}

    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")
    Application.put_env(:ptc_manager, :planning_snapshot_root, "/managed/planning-snapshots")
    Application.put_env(:ptc_manager, :worker_repository_trust_command, GitCommand)
    Application.put_env(:ptc_manager, :worker_repository_trust_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:ptc_manager, key),
          else: Application.put_env(:ptc_manager, key, value)
      end)
    end)

    :ok
  end

  test "temporarily trusts one exact managed snapshot and then revokes it" do
    path = "/managed/planning-snapshots/ptc-manager-planning-a42-deadbeef"

    assert {:ok, :trusted} = WorkerRepositoryTrust.allow(path)

    assert_receive {:git_command, ["config", "--global", "--add", "safe.directory", ^path]}

    assert :ok = WorkerRepositoryTrust.revoke(path)

    assert_receive {:git_command,
                    [
                      "config",
                      "--global",
                      "--fixed-value",
                      "--unset-all",
                      "safe.directory",
                      ^path
                    ]}
  end

  test "does not change worker Git trust for paths outside the managed root" do
    assert {:ok, :not_required} = WorkerRepositoryTrust.allow("/other/repository")
    assert :ok = WorkerRepositoryTrust.revoke("/other/repository")
    refute_receive {:git_command, _args}
  end

  test "does not change Git trust when Herdr runs as the coordinator" do
    Application.delete_env(:ptc_manager, :herdr_run_as_user)
    path = "/managed/planning-snapshots/ptc-manager-planning-a42-deadbeef"

    assert {:ok, :not_required} = WorkerRepositoryTrust.allow(path)
    assert :ok = WorkerRepositoryTrust.revoke(path)
    refute_receive {:git_command, _args}
  end
end
