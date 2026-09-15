defmodule PtcManager.Repository.WorktreePreserverTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorktreePreserver

  test "creates a recoverable bundle and binary patch without changing the worktree" do
    base = Path.join(System.tmp_dir!(), "preserver-#{System.unique_integer([:positive])}")
    root = Path.join(base, "worktrees")
    path = Path.join(root, "job")
    artifacts = Path.join(base, "artifacts")
    recovered = Path.join(base, "recovered")
    branch = "ptc-manager/issue-12-job-34"

    File.mkdir_p!(path)
    File.mkdir_p!(artifacts)
    File.chmod!(root, 0o700)
    {"", 0} = System.cmd("/bin/chmod", ["1700", artifacts])
    on_exit(fn -> File.rm_rf!(base) end)

    git!(path, ["init", "-b", branch])
    git!(path, ["config", "user.name", "Test Agent"])
    git!(path, ["config", "user.email", "agent@example.test"])
    File.write!(Path.join(path, "tracked.txt"), "base\n")
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "base"])
    git!(path, ["commit", "--allow-empty", "-m", "local commit"])
    File.write!(Path.join(path, "tracked.txt"), "changed\n")
    File.write!(Path.join(path, "untracked.bin"), <<0, 1, 2, 255>>)
    before = git!(path, ["status", "--porcelain=v1"])

    previous_worktree_root = Application.get_env(:ptc_manager, :worktree_root)
    previous_artifact_root = Application.get_env(:ptc_manager, :retained_artifact_root)
    Application.put_env(:ptc_manager, :worktree_root, root)
    Application.put_env(:ptc_manager, :retained_artifact_root, artifacts)

    on_exit(fn ->
      restore_env(:worktree_root, previous_worktree_root)
      restore_env(:retained_artifact_root, previous_artifact_root)
    end)

    allocation = %{
      id: 7,
      path: path,
      job: %{branch_name: branch}
    }

    if match?({:unix, :linux}, :os.type()) do
      # Production uses a group-writable drop box that deliberately cannot be
      # listed. The worker must validate and write it without read permission.
      File.chmod!(artifacts, 0o300)
      token = String.duplicate("d", 24)
      script = Application.app_dir(:ptc_manager, "priv/worktree_preserve.py")

      {output, status} =
        System.cmd("/usr/bin/python3", [
          "-I",
          script,
          root,
          path,
          artifacts,
          "7",
          token,
          branch
        ])

      assert status == 0, output
      File.chmod!(artifacts, 0o700)
      File.rm_rf!(Path.join(artifacts, "allocation-7-#{token}"))
      File.chmod!(artifacts, 0o1700)
    end

    assert {:ok, result} = WorktreePreserver.preserve(allocation, String.duplicate("x", 24))
    assert File.dir?(result.preserved_artifact_path)
    assert before == git!(path, ["status", "--porcelain=v1"])

    bundle = Path.join(result.preserved_artifact_path, "commits.bundle")
    patch = Path.join(result.preserved_artifact_path, "worktree.patch")
    System.cmd("/usr/bin/git", ["clone", "-b", branch, bundle, recovered]) |> assert_success!()
    git!(recovered, ["apply", "--binary", patch])
    assert File.read!(Path.join(recovered, "tracked.txt")) == "changed\n"
    assert File.read!(Path.join(recovered, "untracked.bin")) == <<0, 1, 2, 255>>

    assert File.stat!(result.preserved_artifact_path).mode |> Bitwise.band(0o777) == 0o500
    File.chmod!(result.preserved_artifact_path, 0o700)
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("/usr/bin/git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp assert_success!({output, 0}), do: output

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
