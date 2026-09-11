defmodule PtcManager.RepositoryGitProbeTest do
  use ExUnit.Case, async: false

  @moduletag :nightly

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

  test "review evidence matches publication exactly and refuses dirty work" do
    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-7"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "base\nreviewed change\n")
    git!(path, ["commit", "-am", "implementation"])
    repository = %Repository{local_path: path, default_branch: "main"}
    job = %Job{id: 7, issue_id: 42, branch_name: branch}
    assert {:ok, publication} = GitProbe.verify(repository, job)
    assert {:ok, evidence} = GitProbe.review_patch(repository, job, path)
    assert Map.drop(evidence, [:diff]) == publication

    assert Base.encode16(:crypto.hash(:sha256, evidence.diff), case: :lower) ==
             publication.diff_digest

    File.write!(Path.join(path, "uncommitted.txt"), "preserve this work")

    assert {:error, :review_requires_clean_text_commit} =
             GitProbe.review_patch(repository, job, path)

    assert File.read!(Path.join(path, "uncommitted.txt")) == "preserve this work"
  end

  test "a later round reviews only the commits added since the last assessed one" do
    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-7"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "base\nfirst round\n")
    git!(path, ["commit", "-am", "implementation"])
    repository = %Repository{local_path: path, default_branch: "main"}
    job = %Job{id: 7, issue_id: 42, branch_name: branch}
    assert {:ok, first} = GitProbe.review_patch(repository, job, path)
    refute Map.has_key?(first, :review_base_sha)

    File.write!(Path.join(path, "guard.txt"), "answer to the finding\n")
    git!(path, ["add", "guard.txt"])
    git!(path, ["commit", "-m", "answer the finding"])

    assert {:ok, second} = GitProbe.review_patch(repository, job, path, prior(first))
    assert second.review_base_sha == first.head_sha
    assert second.diff =~ "answer to the finding"
    refute second.diff =~ "first round"

    # Publication and cache evidence stay whole-range for the exact commit.
    assert {:ok, publication} = GitProbe.verify(repository, job)
    assert Map.drop(second, [:diff, :review_base_sha]) == publication
  end

  test "an unusable prior commit reviews the whole change instead" do
    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-7"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "base\nonly round\n")
    git!(path, ["commit", "-am", "implementation"])
    repository = %Repository{local_path: path, default_branch: "main"}
    job = %Job{id: 7, issue_id: 42, branch_name: branch}
    assert {:ok, whole} = GitProbe.review_patch(repository, job, path)

    # Unknown, rewritten, identical and merge-base commits all lose their standing.
    candidates =
      [nil] ++
        Enum.map(
          [whole.head_sha, whole.base_sha, String.duplicate("a", 40), "not-a-sha"],
          &%{head_sha: &1, base_sha: whole.base_sha}
        )

    for prior <- candidates do
      assert {:ok, evidence} = GitProbe.review_patch(repository, job, path, prior)
      refute Map.has_key?(evidence, :review_base_sha)
      assert evidence.diff == whole.diff
    end
  end

  test "a rewound default branch reviews the whole change again" do
    path = repository_with_base()
    original_base = String.trim(git!(path, ["rev-parse", "HEAD"]))
    File.write!(Path.join(path, "upstream.txt"), "upstream work\n")
    git!(path, ["add", "upstream.txt"])
    git!(path, ["commit", "-m", "upstream work"])

    branch = "ptc-manager/issue-42-job-7"
    git!(path, ["switch", "-c", branch])
    File.write!(Path.join(path, "README.md"), "base\nfirst round\n")
    git!(path, ["commit", "-am", "implementation"])
    repository = %Repository{local_path: path, default_branch: "main"}
    job = %Job{id: 7, issue_id: 42, branch_name: branch}
    assert {:ok, first} = GitProbe.review_patch(repository, job, path)
    refute first.base_sha == original_base

    File.write!(Path.join(path, "guard.txt"), "answer to the finding\n")
    git!(path, ["add", "guard.txt"])
    git!(path, ["commit", "-m", "answer the finding"])
    git!(path, ["branch", "-f", "main", original_base])

    # The rewind moved commits nobody reviewed into this change; scoping would hide them.
    assert {:ok, second} = GitProbe.review_patch(repository, job, path, prior(first))
    refute Map.has_key?(second, :review_base_sha)
    assert second.base_sha == original_base
    assert second.diff =~ "upstream work"
    assert second.diff =~ "answer to the finding"
  end

  defp prior(evidence), do: Map.take(evidence, [:head_sha, :base_sha])

  test "large generated diffs remain reviewable without truncating their evidence" do
    path = repository_with_base()
    branch = "ptc-manager/issue-42-job-7"
    git!(path, ["switch", "-c", branch])

    File.write!(
      Path.join(path, "schema.json"),
      Jason.encode!(%{"description" => String.duplicate("x", 600_000)})
    )

    git!(path, ["add", "."])
    git!(path, ["commit", "-m", "generated schema"])
    repository = %Repository{local_path: path, default_branch: "main"}
    job = %Job{id: 7, issue_id: 42, branch_name: branch}
    assert {:ok, publication} = GitProbe.verify(repository, job)
    assert {:ok, evidence} = GitProbe.review_patch(repository, job, path)
    assert evidence.diff_digest == publication.diff_digest
    assert evidence.diff == nil
    assert evidence.diff_on_disk
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

  @tag nightly: false
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
    assert "--as=536870912" in args
    refute ~s(exec "$@" 2>/dev/null) in args
    assert "/usr/bin/git" in args
    assert GitProbe.timeout_duration() == "15.0s"
  end

  test "failed Git commands retain bounded diagnostics without contaminating successful output" do
    path = repository_with_base()
    binary = Path.join(path, "fake-git")
    File.write!(binary, "#!/bin/sh\nprintf 'Cannot allocate memory' >&2\nexit 128\n")
    File.chmod!(binary, 0o755)
    previous = Application.fetch_env(:ptc_manager, :git_binary)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ptc_manager, :git_binary, value)
        :error -> Application.delete_env(:ptc_manager, :git_binary)
      end
    end)

    Application.put_env(:ptc_manager, :git_binary, binary)

    assert {:error, {:git_failed, "symbolic-ref", 128, message}} =
             GitProbe.reclaimable(path, "main", "head")

    assert message =~ "Cannot allocate memory"

    File.write!(
      binary,
      "#!/bin/sh\nprintf '" <> String.duplicate("x", 6000) <> "final diagnostic' >&2\nexit 128\n"
    )

    assert {:error, {:git_failed, "symbolic-ref", 128, bounded}} =
             GitProbe.reclaimable(path, "main", "head")

    assert byte_size(bounded) <= 2000
    assert bounded =~ "final diagnostic"
    File.write!(binary, "#!/bin/sh\nprintf 'diagnostic warning' >&2\nprintf 'main'\n")
    # Successful stderr must never become part of parsed refs or patch hashes.
    {command, args} = GitProbe.command(binary, [])
    assert {"main", 0} = System.cmd(command, args)
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

  test "an empty worktree is clean and adds no commit beyond the default branch" do
    path = repository_with_base()
    worktree = path <> "-worktree"
    on_exit(fn -> File.rm_rf!(worktree) end)
    git!(path, ["worktree", "add", "-b", "ptc-manager/issue-2-job-28", worktree, "main"])

    assert :ok = GitProbe.empty_worktree(worktree, "main")

    File.write!(Path.join(worktree, "notes.txt"), "scratch\n")
    assert {:error, :worktree_has_changes} = GitProbe.empty_worktree(worktree, "main")

    git!(worktree, ["add", "notes.txt"])
    git!(worktree, ["commit", "-m", "partial work"])
    assert {:error, :worktree_has_commits} = GitProbe.empty_worktree(worktree, "main")

    assert {:error, :worktree_path_unavailable} =
             GitProbe.empty_worktree(worktree <> "-missing", "main")
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
