defmodule PtcManager.Repository.WorkerGitTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorkerGit

  test "terminates a worker Git command at its deadline" do
    root = Path.join(System.tmp_dir!(), "ptc-worker-git-#{System.unique_integer([:positive])}")
    binary = Path.join(root, "slow-git")
    File.mkdir_p!(root)

    File.write!(binary, "#!/bin/sh\nsleep 5\n")
    File.chmod!(binary, 0o700)

    previous_binary = Application.get_env(:ptc_manager, :herdr_git_binary)
    previous_user = Application.get_env(:ptc_manager, :herdr_run_as_user)

    Application.put_env(:ptc_manager, :herdr_git_binary, binary)
    Application.delete_env(:ptc_manager, :herdr_run_as_user)

    on_exit(fn ->
      restore_env(:herdr_git_binary, previous_binary)
      restore_env(:herdr_run_as_user, previous_user)
      File.rm_rf!(root)
    end)

    started = System.monotonic_time(:millisecond)
    assert {output, 124} = WorkerGit.run(["status"], 20)
    assert output =~ "timed out"
    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
