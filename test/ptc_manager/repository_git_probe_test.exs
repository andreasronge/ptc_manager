defmodule PtcManager.RepositoryGitProbeTest do
  use ExUnit.Case, async: false

  alias PtcManager.Operations.{Job, Repository}
  alias PtcManager.Repository.GitProbe

  test "verifies the exact committed diff on the dedicated job branch" do
    path = repository_with_base()

    branch = "ptc-manager/issue-42-job-7"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "base\nverified change\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "implement issue"])

    repository = %Repository{local_path: path, default_branch: "main"}
    job = %Job{id: 7, issue_id: 42, branch_name: branch}

    assert {:ok, result} = GitProbe.verify(repository, job)
    assert result.commit_count == 1
    assert result.base_sha =~ ~r/\A[0-9a-f]{40,64}\z/
    assert result.head_sha =~ ~r/\A[0-9a-f]{40,64}\z/
    assert result.base_sha != result.head_sha
    assert result.diff_digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "rejects an empty commit" do
    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-8"
    git!(path, ["switch", "-c", branch])
    git!(path, ["commit", "--allow-empty", "-m", "empty implementation"])

    assert {:error, :no_tree_changes} =
             GitProbe.verify(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 8, issue_id: 42, branch_name: branch}
             )
  end

  test "rejects commits whose net tree change is empty" do
    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-9"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "temporary\n")
    git!(path, ["commit", "-am", "temporary change"])
    File.write!(Path.join(path, "README.md"), "base\n")
    git!(path, ["commit", "-am", "revert temporary change"])

    assert {:error, :no_tree_changes} =
             GitProbe.verify(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 9, issue_id: 42, branch_name: branch}
             )
  end

  test "stops digesting a diff beyond the configured byte limit" do
    previous = Application.get_env(:ptc_manager, :git_diff_max_bytes)
    Application.put_env(:ptc_manager, :git_diff_max_bytes, 100)
    on_exit(fn -> Application.put_env(:ptc_manager, :git_diff_max_bytes, previous) end)

    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-10"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "large.txt"), String.duplicate("bounded output\n", 100))
    git!(path, ["add", "large.txt"])
    git!(path, ["commit", "-m", "large change"])

    assert {:error, :git_diff_too_large} =
             GitProbe.verify(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 10, issue_id: 42, branch_name: branch}
             )
  end

  test "rejects an oversized changed blob before generating its patch" do
    previous = Application.get_env(:ptc_manager, :git_max_blob_bytes)
    Application.put_env(:ptc_manager, :git_max_blob_bytes, 10)
    on_exit(fn -> Application.put_env(:ptc_manager, :git_max_blob_bytes, previous) end)

    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-11"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "blob.txt"), String.duplicate("x", 100))
    git!(path, ["add", "blob.txt"])
    git!(path, ["commit", "-m", "oversized blob"])

    assert {:error, :git_blob_too_large} =
             GitProbe.verify(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 11, issue_id: 42, branch_name: branch}
             )
  end

  test "treats magic-looking changed filenames as literal pathspecs" do
    previous = Application.get_env(:ptc_manager, :git_max_blob_bytes)
    Application.put_env(:ptc_manager, :git_max_blob_bytes, 10)
    on_exit(fn -> Application.put_env(:ptc_manager, :git_max_blob_bytes, previous) end)

    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-12"
    git!(path, ["switch", "-c", branch])
    File.mkdir_p!(Path.join(path, ":"))
    File.write!(Path.join([path, ":", "README.md"]), String.duplicate("x", 100))
    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "magic-looking path"])

    assert {:error, :git_blob_too_large} =
             GitProbe.verify(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 12, issue_id: 42, branch_name: branch}
             )
  end

  test "constructs a scrubbed cross-UID verifier command with an OS timeout" do
    settings =
      for key <- [
            :git_run_as_user,
            :git_verifier_home,
            :git_timeout_binary,
            :git_memory_limit_binary
          ],
          into: %{} do
        {key, Application.get_env(:ptc_manager, key)}
      end

    on_exit(fn ->
      Enum.each(settings, fn {key, value} -> Application.put_env(:ptc_manager, key, value) end)
    end)

    Application.put_env(:ptc_manager, :git_run_as_user, "ptc-manager-verifier")
    Application.put_env(:ptc_manager, :git_verifier_home, "/var/lib/ptc_manager-verifier")
    Application.put_env(:ptc_manager, :git_timeout_binary, "/usr/bin/timeout")
    Application.put_env(:ptc_manager, :git_memory_limit_binary, "/usr/bin/prlimit")

    assert {"/usr/bin/sudo", args} = GitProbe.command("/usr/bin/git", ["status"])

    assert Enum.take(args, 7) == [
             "-n",
             "-H",
             "-u",
             "ptc-manager-verifier",
             "--",
             "/usr/bin/env",
             "-i"
           ]

    assert "HOME=/var/lib/ptc_manager-verifier" in args
    assert "GIT_CONFIG_NOSYSTEM=1" in args
    assert "GIT_LITERAL_PATHSPECS=1" in args
    assert "/usr/bin/timeout" in args
    assert "15.0s" in args
    assert "/usr/bin/prlimit" in args
    assert "--as=268435456" in args
    assert ~s(exec "$@" 2>/dev/null) in args
    assert "/usr/bin/git" in args
    assert GitProbe.timeout_duration() == "15.0s"
  end

  test "accepts only repair heads that preserve the published history" do
    path = repository_with_base()
    base_sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(path, "README.md"), "base\nrepair\n")
    git!(path, ["commit", "-am", "repair pull request"])
    repaired_sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    assert :ok = GitProbe.descendant?(path, base_sha, repaired_sha)
    assert {:error, :repair_not_fast_forward} = GitProbe.descendant?(path, repaired_sha, base_sha)
  end

  test "repair verification stays pinned to GitHub's exact base commit" do
    path = repository_with_base()
    github_base_sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()
    branch = "ptc-manager/issue-42-job-13"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "base\nrepair\n")
    git!(path, ["commit", "-am", "repair pull request"])
    repaired_sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    # Simulate an agent moving the mutable local default-branch ref.
    git!(path, ["branch", "-f", "main", repaired_sha])

    assert {:ok, verified} =
             GitProbe.verify_repair_at(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 13, issue_id: 42, branch_name: branch},
               path,
               github_base_sha
             )

    assert verified.base_sha == github_base_sha
    assert verified.head_sha == repaired_sha
    assert verified.commit_count == 1

    assert {:error, :repair_base_missing} =
             GitProbe.verify_repair_at(
               %Repository{local_path: path, default_branch: "main"},
               %Job{id: 13, issue_id: 42, branch_name: branch},
               path,
               String.duplicate("f", 40)
             )
  end

  test "reclaimable worktrees must be clean and checked out on the expected branch" do
    path = repository_with_base()
    expected_head = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    assert :ok = GitProbe.reclaimable(path, "main", expected_head)

    File.write!(Path.join(path, "leftover.txt"), "dirty\n")
    assert {:error, :worktree_changed} = GitProbe.reclaimable(path, "main", expected_head)
    File.rm!(Path.join(path, "leftover.txt"))

    git!(path, ["switch", "-c", "other"])
    assert {:error, :worktree_changed} = GitProbe.reclaimable(path, "main", expected_head)
  end

  defp repository_with_base do
    path =
      Path.join(System.tmp_dir!(), "ptc-manager-git-probe-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(path, "README.md"), "base\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "base"])
    path
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    output
  end
end
