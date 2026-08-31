defmodule PtcManager.Repository.SourceSnapshotTest do
  use ExUnit.Case, async: false

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.SourceSnapshot

  setup do
    previous_binary = Application.get_env(:ptc_manager, :planning_git_binary)
    previous_path = Application.get_env(:ptc_manager, :repository_path)
    previous_root = Application.get_env(:ptc_manager, :planning_snapshot_root)

    worktree_root =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-planning-snapshots-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:ptc_manager, :planning_git_binary, "/usr/bin/git")
    Application.delete_env(:ptc_manager, :repository_path)
    Application.put_env(:ptc_manager, :planning_snapshot_root, worktree_root)

    on_exit(fn ->
      restore_env(:planning_git_binary, previous_binary)
      restore_env(:repository_path, previous_path)
      restore_env(:planning_snapshot_root, previous_root)
      File.rm_rf(worktree_root)
    end)

    %{snapshot_root: worktree_root}
  end

  test "captures the exact checkout ref and commit" do
    path =
      Path.join(System.tmp_dir!(), "ptc-source-snapshot-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main", path], stderr_to_stdout: true)
    File.write!(Path.join(path, "README.md"), "snapshot\n")
    assert {_, 0} = System.cmd("git", ["-C", path, "add", "README.md"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 path,
                 "-c",
                 "user.name=PtcManager Test",
                 "-c",
                 "user.email=ptc@example.invalid",
                 "commit",
                 "-m",
                 "initial"
               ],
               stderr_to_stdout: true
             )

    {expected_sha, 0} =
      System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true)

    repository = %Repository{local_path: path, default_branch: "main"}

    assert {:ok, snapshot} = SourceSnapshot.capture(repository)
    assert snapshot.sha == String.trim(expected_sha)
    assert snapshot.ref == "main"
  end

  test "rejects an unavailable checkout" do
    repository = %Repository{local_path: "/missing/ptc-source-snapshot", default_branch: "main"}
    assert {:error, :repository_path_unavailable} = SourceSnapshot.capture(repository)
  end

  test "marks every source Git command as safe for the coordinator identity" do
    assert SourceSnapshot.git_args("/srv/ptc_runner", ["rev-parse", "HEAD"]) == [
             "-c",
             "safe.directory=/srv/ptc_runner",
             "-C",
             "/srv/ptc_runner",
             "--no-optional-locks",
             "rev-parse",
             "HEAD"
           ]
  end

  test "rejects a broad configured root before changing its permissions" do
    path =
      Path.join(System.tmp_dir!(), "ptc-source-root-guard-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main", path], stderr_to_stdout: true)
    File.write!(Path.join(path, "README.md"), "snapshot\n")
    assert {_, 0} = System.cmd("git", ["-C", path, "add", "README.md"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 path,
                 "-c",
                 "user.name=PtcManager Test",
                 "-c",
                 "user.email=ptc@example.invalid",
                 "commit",
                 "-m",
                 "initial"
               ],
               stderr_to_stdout: true
             )

    before_mode = File.stat!("/").mode
    Application.put_env(:ptc_manager, :planning_snapshot_root, "/")
    repository = %Repository{local_path: path, default_branch: "main"}

    assert {:error, :repository_snapshot_root_unavailable} =
             SourceSnapshot.prepare(repository, 79, %{})

    assert File.stat!("/").mode == before_mode
  end

  test "rejects a symlinked configured root without changing its target permissions" do
    path =
      Path.join(System.tmp_dir!(), "ptc-source-root-link-#{System.unique_integer([:positive])}")

    parent =
      Path.join(System.tmp_dir!(), "ptc-source-root-parent-#{System.unique_integer([:positive])}")

    target =
      Path.join(System.tmp_dir!(), "ptc-source-root-target-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.mkdir_p!(parent)
    File.mkdir_p!(target)
    File.chmod!(target, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    on_exit(fn -> File.rm_rf(parent) end)
    on_exit(fn -> File.rm_rf(target) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main", path], stderr_to_stdout: true)
    File.write!(Path.join(path, "README.md"), "snapshot\n")
    assert {_, 0} = System.cmd("git", ["-C", path, "add", "README.md"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 path,
                 "-c",
                 "user.name=PtcManager Test",
                 "-c",
                 "user.email=ptc@example.invalid",
                 "commit",
                 "-m",
                 "initial"
               ],
               stderr_to_stdout: true
             )

    root = Path.join(parent, "planning-snapshots")
    assert :ok = File.ln_s(target, root)
    before_mode = File.stat!(target).mode
    Application.put_env(:ptc_manager, :planning_snapshot_root, root)
    repository = %Repository{local_path: path, default_branch: "main"}

    assert {:error, :repository_snapshot_root_unavailable} =
             SourceSnapshot.prepare(repository, 80, %{})

    assert File.stat!(target).mode == before_mode
  end

  test "rejects a tracked symlink that escapes the read-only snapshot" do
    path =
      Path.join(System.tmp_dir!(), "ptc-source-symlink-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main", path], stderr_to_stdout: true)
    assert :ok = File.ln_s("/tmp/outside-planning-snapshot", Path.join(path, "outside"))
    assert {_, 0} = System.cmd("git", ["-C", path, "add", "outside"])

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 path,
                 "-c",
                 "user.name=PtcManager Test",
                 "-c",
                 "user.email=ptc@example.invalid",
                 "commit",
                 "-m",
                 "symlink"
               ],
               stderr_to_stdout: true
             )

    repository = %Repository{local_path: path, default_branch: "main"}

    assert {:error, :repository_snapshot_symlink_escape} =
             SourceSnapshot.prepare(repository, 77, %{})
  end

  test "rejects a symlink that leaves the snapshot even when external indirection points back in",
       %{
         snapshot_root: snapshot_root
       } do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-source-indirect-symlink-#{System.unique_integer([:positive])}"
      )

    external =
      Path.join(
        System.tmp_dir!(),
        "ptc-source-external-symlink-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    File.mkdir_p!(external)
    on_exit(fn -> File.rm_rf(path) end)
    on_exit(fn -> File.rm_rf(external) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main", path], stderr_to_stdout: true)
    File.write!(Path.join(path, "evidence.txt"), "original\n")
    assert :ok = File.ln_s(Path.join(external, "back"), Path.join(path, "indirect"))

    assert {_, 0} =
             System.cmd("git", ["-C", path, "add", "evidence.txt", "indirect"],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 path,
                 "-c",
                 "user.name=PtcManager Test",
                 "-c",
                 "user.email=ptc@example.invalid",
                 "commit",
                 "-m",
                 "indirect symlink"
               ],
               stderr_to_stdout: true
             )

    {sha, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true)
    sha = String.trim(sha)

    snapshot_path =
      Path.join(snapshot_root, "ptc-manager-planning-a78-#{String.slice(sha, 0, 12)}")

    assert :ok = File.ln_s(Path.join(snapshot_path, "evidence.txt"), Path.join(external, "back"))

    repository = %Repository{local_path: path, default_branch: "main"}

    assert {:error, :repository_snapshot_symlink_escape} =
             SourceSnapshot.prepare(repository, 78, %{})
  end

  test "pins planning evidence in a read-only clone and removes it even after HEAD changes", %{
    snapshot_root: snapshot_root
  } do
    path =
      Path.join(System.tmp_dir!(), "ptc-source-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    assert {_, 0} = System.cmd("git", ["init", "-b", "main", path], stderr_to_stdout: true)
    File.write!(Path.join(path, "evidence.txt"), "original\n")
    assert :ok = File.ln_s("evidence.txt", Path.join(path, "current-evidence.txt"))

    assert {_, 0} =
             System.cmd("git", ["-C", path, "add", "evidence.txt", "current-evidence.txt"])

    assert {_, 0} =
             System.cmd(
               "git",
               [
                 "-C",
                 path,
                 "-c",
                 "user.name=PtcManager Test",
                 "-c",
                 "user.email=ptc@example.invalid",
                 "commit",
                 "-m",
                 "initial"
               ],
               stderr_to_stdout: true
             )

    git_proxy = Path.join(path, "reject-local-clone")

    File.write!(
      git_proxy,
      """
      #!/bin/sh
      for argument do
        if [ "$argument" = "clone" ]; then
          echo "local clone transport is forbidden in this test" >&2
          exit 97
        fi
      done
      exec /usr/bin/git "$@"
      """
    )

    File.chmod!(git_proxy, 0o700)
    Application.put_env(:ptc_manager, :planning_git_binary, git_proxy)

    repository = %Repository{local_path: path, default_branch: "main"}

    assert {:ok, snapshot} = SourceSnapshot.prepare(repository, 42, %{})
    assert File.stat!(snapshot.path).gid == File.stat!(snapshot_root).gid
    assert File.read!(Path.join(snapshot.path, "evidence.txt")) == "original\n"
    assert File.read!(Path.join(snapshot.path, "current-evidence.txt")) == "original\n"
    refute File.exists?(Path.join([snapshot.path, ".git", "ptc-manager-source.bundle"]))
    assert :ok = SourceSnapshot.verify(repository, snapshot.path, snapshot.sha)

    assert {:ok, second_snapshot} = SourceSnapshot.prepare(repository, 43, %{})

    assert :ok =
             SourceSnapshot.release(repository, 43, %{
               "source_sha" => second_snapshot.sha,
               "source_path" => second_snapshot.path
             })

    File.write!(Path.join(path, "evidence.txt"), "uncommitted live checkout change\n")
    assert File.read!(Path.join(snapshot.path, "evidence.txt")) == "original\n"

    assert {:error, :eacces} =
             File.write(Path.join(snapshot.path, "injected.txt"), "not committed\n")

    assert {_, 0} =
             System.cmd("/bin/chmod", ["-R", "u+w", snapshot.path], stderr_to_stdout: true)

    assert :ok =
             File.chmod(
               Path.join([snapshot.path, ".git", ".ptc-manager-planning-snapshot"]),
               0o440
             )

    assert {_, 0} =
             System.cmd("git", ["-C", snapshot.path, "checkout", "-b", "changed-after-crash"],
               stderr_to_stdout: true
             )

    stored = %{"source_sha" => snapshot.sha, "source_path" => snapshot.path}
    assert :ok = SourceSnapshot.release(repository, 42, stored)
    refute File.exists?(snapshot.path)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
