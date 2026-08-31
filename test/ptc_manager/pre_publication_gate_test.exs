defmodule PtcManager.Repository.PrePublicationGateTest do
  use ExUnit.Case, async: false

  alias PtcManager.Operations.{Job, PrPublication, WorktreeAllocation}
  alias PtcManager.Repository.{Contract, PrePublicationGate}
  alias PtcManager.Repository.PrePublicationGate.Runner

  defmodule PassingRunner do
    def run(path, sha, bootstrap, bootstrap_timeout_ms, command, timeout_ms) do
      send(
        Process.get(:gate_test_pid),
        {:gate_run, path, sha, bootstrap, bootstrap_timeout_ms, command, timeout_ms}
      )

      {:ok,
       %{exit_status: 0, output: "all checks passed", output_truncated: false, duration_ms: 12}}
    end
  end

  defmodule DirtyRunner do
    def run(path, _sha, _bootstrap, _bootstrap_timeout_ms, _command, _timeout_ms) do
      File.write!(Path.join(path, "generated.txt"), "dirty")
      {:ok, %{exit_status: 0, output: "passed", output_truncated: false, duration_ms: 4}}
    end
  end

  setup do
    Process.put(:gate_test_pid, self())
    :ok
  end

  test "binds a successful credential-free execution to the exact clean head" do
    {path, sha} = repository()
    publication = publication(path, sha)

    assert {:ok, evidence} = PrePublicationGate.verify(publication, PassingRunner)
    assert evidence.status == "passed"
    assert evidence.verified_sha == sha
    assert evidence.config_digest == publication.job.pre_publication_config_digest
    assert evidence.exit_status == 0

    assert_receive {:gate_run, ^path, ^sha, "./scripts/ptc/bootstrap", 60_000,
                    "./scripts/ci/pre-publication", 60_000}
  end

  test "does not run in a dirty worktree and rejects dirt created by the gate" do
    {path, sha} = repository()
    publication = publication(path, sha)
    File.write!(Path.join(path, "before.txt"), "dirty")

    assert {:error, :worktree_changed} =
             PrePublicationGate.verify(publication, PassingRunner)

    refute_receive {:gate_run, _, _, _, _, _, _}

    File.rm!(Path.join(path, "before.txt"))

    assert {:error, :worktree_changed} =
             PrePublicationGate.verify(publication, DirtyRunner)
  end

  test "rejects frozen commands that no longer match their digest" do
    {path, sha} = repository()
    publication = publication(path, sha)

    changed = put_in(publication.job.pre_publication_command, "true")

    assert {:error, :pre_publication_gate_config_changed} =
             PrePublicationGate.verify(changed, PassingRunner)

    refute_receive {:gate_run, _, _, _, _, _, _}
  end

  test "constructs an empty credential environment under an OS timeout" do
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, "/usr/bin/timeout")
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, "ptc-manager-verifier")
    Application.put_env(:ptc_manager, :pre_publication_home, "/var/lib/ptc-manager-verifier")
    Application.put_env(:ptc_manager, :pre_publication_path, "/usr/local/bin:/usr/bin:/bin")

    assert {:ok, "/usr/bin/sudo", args} =
             Runner.command(
               "/srv/repository-worktree",
               String.duplicate("a", 40),
               "mix deps.get",
               10_000,
               "mix precommit",
               45_000
             )

    assert Enum.take(args, 7) == [
             "-n",
             "-H",
             "-u",
             "ptc-manager-verifier",
             "--",
             "/usr/bin/env",
             "-i"
           ]

    assert "HOME=/var/lib/ptc-manager-verifier" in args
    assert "MIX_HOME=/opt/ptc-manager-gate-mix" in args
    assert "MIX_ENV=test" in args
    assert "GIT_CONFIG_GLOBAL=/dev/null" in args
    assert "GIT_NO_REPLACE_OBJECTS=1" in args
    assert "/usr/bin/timeout" in args
    assert "85s" in args
    assert "/srv/repository-worktree" in args
    assert String.duplicate("a", 40) in args
    assert "mix deps.get" in args
    assert "10s" in args
    assert "mix precommit" in args
    assert "45s" in args
    refute Enum.any?(args, &String.contains?(&1, "GITHUB"))
    refute Enum.any?(args, &String.contains?(&1, "TOKEN"))
  end

  test "bounds retained output and lets the OS timeout report command expiry" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    Application.put_env(:ptc_manager, :pre_publication_git_binary, System.find_executable("git"))
    {path, sha} = repository()

    assert {:ok, large} =
             Runner.run(
               path,
               sha,
               "true",
               5_000,
               "awk 'BEGIN { for (i = 0; i < 70000; i++) printf \"x\" }'",
               5_000
             )

    assert large.exit_status == 0, inspect(large)
    assert byte_size(large.output) == 65_536
    assert large.output_truncated

    assert {:ok, expired} = Runner.run(path, sha, "true", 5_000, "sleep 2", 10)
    assert expired.exit_status == 124
    assert expired.duration_ms < 5_000

    isolated_home_command = "test ! -e \"$HOME/leak\" && touch \"$HOME/leak\""

    assert {:ok, %{exit_status: 0}} =
             Runner.run(path, sha, "true", 5_000, isolated_home_command, 5_000)

    assert {:ok, %{exit_status: 0}} =
             Runner.run(path, sha, "true", 5_000, isolated_home_command, 5_000)
  end

  test "rejects a gate that moves the disposable checkout to another clean commit" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    Application.put_env(:ptc_manager, :pre_publication_git_binary, System.find_executable("git"))
    {path, sha} = repository()

    assert {:ok, moved} =
             Runner.run(path, sha, "true", 5_000, "git reset --hard HEAD^", 5_000)

    assert moved.exit_status == 120, inspect(moved)
    assert moved.output =~ "changed the disposable checkout HEAD"
  end

  test "rejects tracked changes hidden with assume-unchanged" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    Application.put_env(:ptc_manager, :pre_publication_git_binary, System.find_executable("git"))
    {path, sha} = repository()

    command =
      "git update-index --assume-unchanged README.md && printf 'hidden change\\n' > README.md"

    assert {:ok, hidden} = Runner.run(path, sha, "true", 5_000, command, 5_000)
    assert hidden.exit_status == 122, inspect(hidden)
    assert hidden.output =~ "changed tracked contents"
  end

  test "rejects tracked changes hidden by a repository clean filter" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    Application.put_env(:ptc_manager, :pre_publication_git_binary, System.find_executable("git"))
    {path, _sha} = repository()
    File.write!(Path.join(path, ".gitattributes"), "README.md filter=hide-change\n")
    git!(path, ["add", ".gitattributes"])
    git!(path, ["commit", "-m", "declare clean filter"])
    sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    command =
      ~s(git config filter.hide-change.clean "printf 'base\\nchange\\n'" && printf 'hidden change\\n' > README.md)

    assert {:ok, hidden} = Runner.run(path, sha, "true", 5_000, command, 5_000)
    assert hidden.exit_status == 122, inspect(hidden)
    assert hidden.output =~ "Repository-local Git filters"
  end

  test "fails closed when tracked-tree inspection fails" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    {path, sha} = repository()
    wrapper = failing_git_wrapper!(Path.dirname(path), "ls-tree")
    Application.put_env(:ptc_manager, :pre_publication_git_binary, wrapper)

    assert {:ok, failed} = Runner.run(path, sha, "true", 5_000, "true", 5_000)
    assert failed.exit_status == 121, inspect(failed)
    assert failed.output =~ "Tracked-tree inspection failed"
  end

  test "fails closed when clean-status inspection fails" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    {path, sha} = repository()
    wrapper = failing_git_wrapper!(Path.dirname(path), "status")
    Application.put_env(:ptc_manager, :pre_publication_git_binary, wrapper)

    assert {:ok, failed} = Runner.run(path, sha, "true", 5_000, "true", 5_000)
    assert failed.exit_status == 121, inspect(failed)
    assert failed.output =~ "Git status inspection failed"
  end

  test "accepts an unchanged checkout with eol and ident transformations" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    Application.put_env(:ptc_manager, :pre_publication_git_binary, System.find_executable("git"))
    {path, _sha} = repository()
    File.write!(Path.join(path, ".gitattributes"), "README.md ident eol=crlf\n")
    File.write!(Path.join(path, "README.md"), "base\nchange\n$Id$\n")
    git!(path, ["add", ".gitattributes", "README.md"])
    git!(path, ["commit", "-m", "declare checkout transformations"])
    sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, transformed} = Runner.run(path, sha, "true", 5_000, "true", 5_000)
    assert transformed.exit_status == 0, inspect(transformed)
  end

  test "rejects repositories with submodules until recursive validation is supported" do
    timeout = System.find_executable("timeout") || raise "timeout executable is required"
    previous = gate_settings()
    on_exit(fn -> restore_gate_settings(previous) end)

    Application.put_env(:ptc_manager, :pre_publication_timeout_binary, timeout)
    Application.put_env(:ptc_manager, :pre_publication_run_as_user, nil)
    Application.put_env(:ptc_manager, :pre_publication_home, System.tmp_dir!())
    Application.put_env(:ptc_manager, :pre_publication_git_binary, System.find_executable("git"))
    {path, existing_sha} = repository()

    git!(path, [
      "update-index",
      "--add",
      "--cacheinfo",
      "160000,#{existing_sha},vendor/dependency"
    ])

    git!(path, ["commit", "-m", "add gitlink"])
    sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    command = "mkdir -p vendor/dependency && printf 'dirty\\n' > vendor/dependency/file.txt"
    assert {:ok, rejected} = Runner.run(path, sha, "true", 5_000, command, 5_000)
    assert rejected.exit_status == 121, inspect(rejected)
    assert rejected.output =~ "Submodules are not supported"
  end

  defp publication(path, sha) do
    branch = "ptc-manager/issue-1-job-1"

    contract = %Contract{
      version: 1,
      bootstrap_command: "./scripts/ptc/bootstrap",
      bootstrap_timeout_minutes: 1,
      before_publish_command: "./scripts/ci/pre-publication",
      verification_timeout_minutes: 1
    }

    %PrPublication{
      id: 1,
      head_sha: sha,
      branch_name: branch,
      job: %Job{
        id: 1,
        branch_name: branch,
        pre_publication_bootstrap_command: contract.bootstrap_command,
        pre_publication_bootstrap_timeout_ms: contract.bootstrap_timeout_minutes * 60_000,
        pre_publication_command: contract.before_publish_command,
        pre_publication_timeout_ms: contract.verification_timeout_minutes * 60_000,
        pre_publication_config_digest: Contract.publication_digest(contract),
        worktree_allocation: %WorktreeAllocation{path: path}
      }
    }
  end

  defp repository do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-pre-publication-#{System.unique_integer([:positive, :monotonic])}"
      )

    repository = Path.join(root, "repository")
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(repository)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repository, ["init", "-b", "main"])
    git!(repository, ["config", "user.email", "test@example.com"])
    git!(repository, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(repository, "README.md"), "base\n")
    git!(repository, ["add", "README.md"])
    git!(repository, ["commit", "-m", "base"])

    git!(repository, [
      "worktree",
      "add",
      "-b",
      "ptc-manager/issue-1-job-1",
      worktree
    ])

    File.write!(Path.join(worktree, "README.md"), "base\nchange\n")
    git!(worktree, ["commit", "-am", "change"])
    sha = git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()
    {worktree, sha}
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end

  defp failing_git_wrapper!(root, failed_command) do
    wrapper = Path.join(root, "git-fails-#{failed_command}")
    real_git = System.find_executable("git") || raise "git executable is required"

    File.write!(
      wrapper,
      """
      #!/bin/sh
      for argument in "$@"; do
        if test "$argument" = "#{failed_command}"; then
          exit 86
        fi
      done
      exec "#{real_git}" "$@"
      """
    )

    File.chmod!(wrapper, 0o755)
    wrapper
  end

  defp gate_settings do
    for key <- [
          :pre_publication_timeout_binary,
          :pre_publication_run_as_user,
          :pre_publication_home,
          :pre_publication_mix_home,
          :pre_publication_path,
          :pre_publication_git_binary
        ],
        into: %{} do
      {key, Application.get_env(:ptc_manager, key)}
    end
  end

  defp restore_gate_settings(settings) do
    Enum.each(settings, fn {key, value} -> Application.put_env(:ptc_manager, key, value) end)
  end
end
