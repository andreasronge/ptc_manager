defmodule PtcManager.Repository.WorktreePreserverTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorktreePreserver

  test "the helper refuses a branch outside the job branch format before touching anything" do
    script = Application.app_dir(:ptc_manager, "priv/worktree_preserve.py")
    token = String.duplicate("d", 24)

    for branch <- [
          "main",
          "issue-1-job-2",
          "bugfix/issue-1-job-2/x",
          "a/b/c/d/issue-1-job-2",
          "refs/heads/issue-1-job-2",
          "Origin/issue-1-job-2",
          "bug..fix/issue-1-job-2",
          "bugfix./issue-1-job-2",
          "bugfix.lock/issue-1-job-2",
          "-bugfix/issue-1-job-2"
        ] do
      {_output, status} =
        System.cmd(
          "/usr/bin/python3",
          [
            "-I",
            script,
            "/nonexistent",
            "/nonexistent/job",
            "/nonexistent-artifacts",
            "7",
            token,
            branch
          ],
          stderr_to_stdout: true
        )

      assert status == 2, branch
    end
  end

  test "creates a recoverable bundle and binary patch without changing the worktree" do
    base = Path.join(System.tmp_dir!(), "preserver-#{System.unique_integer([:positive])}")
    root = Path.join(base, "worktrees")
    path = Path.join(root, "job")
    artifacts = Path.join(base, "artifacts")
    write_only_artifacts = Path.join(base, "write-only-artifacts")
    recovered = Path.join(base, "recovered")
    # A configured multi-segment prefix, not only the legacy ptc-manager/.
    branch = "team/bugfix/issue-12-job-34"

    File.mkdir_p!(path)
    File.mkdir_p!(artifacts)
    File.mkdir_p!(write_only_artifacts)
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
      File.chmod!(write_only_artifacts, 0o300)
      token = String.duplicate("d", 24)
      script = Application.app_dir(:ptc_manager, "priv/worktree_preserve.py")

      {output, status} =
        System.cmd("/usr/bin/python3", [
          "-I",
          script,
          root,
          path,
          write_only_artifacts,
          "7",
          token,
          branch
        ])

      assert status == 0, output
      File.chmod!(write_only_artifacts, 0o700)
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
