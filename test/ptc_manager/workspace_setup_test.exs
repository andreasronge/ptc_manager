defmodule PtcManager.Repository.WorkspaceSetupTest do
  use ExUnit.Case, async: true

  @moduletag :nightly

  alias PtcManager.Operations.Job
  alias PtcManager.Repository.{Contract, WorkspaceSetup}

  test "runs the exact checked-in setup script and records bounded evidence" do
    fixture =
      workspace_fixture(
        "mkdir -p .cache\n" <>
          "printf 'dependencies ready\\n'\n" <>
          "printf 'PTC_SETUP_METRIC cache_state=hit\\n'\n" <>
          "printf 'PTC_SETUP_METRIC cache_restore_ms=125\\n'\n" <>
          "printf 'PTC_SETUP_METRIC dependencies_ms=875\\n'\n"
      )

    on_exit(fn -> File.rm_rf!(fixture.root) end)

    assert {:ok, report} = WorkspaceSetup.run(fixture.worktree, fixture.job)
    assert report.state == "passed"
    assert report.script == "scripts/ptc/setup-worktree"
    assert report.source_sha == fixture.sha
    assert report.exit_status == 0
    assert report.output =~ "dependencies ready\n"
    assert report.cache_state == "hit"

    assert report.phase_durations == %{
             "cache_restore_ms" => 125,
             "dependencies_ms" => 875
           }

    assert report.duration_ms >= 0
    assert DateTime.compare(report.started_at, report.ended_at) in [:lt, :eq]
    refute report.output_truncated
  end

  test "ignores malformed or unknown setup metrics" do
    fixture =
      workspace_fixture(
        "printf 'PTC_SETUP_METRIC cache_state=surprise\\n'\n" <>
          "printf 'PTC_SETUP_METRIC dependencies_ms=-1\\n'\n" <>
          "printf 'PTC_SETUP_METRIC unknown_ms=42\\n'\n"
      )

    on_exit(fn -> File.rm_rf!(fixture.root) end)

    assert {:ok, report} = WorkspaceSetup.run(fixture.worktree, fixture.job)
    assert report.cache_state == nil
    assert report.phase_durations == %{}
  end

  test "a non-zero setup fails before an agent can be launched" do
    fixture = workspace_fixture("printf 'missing tool\\n'\nexit 17\n")
    on_exit(fn -> File.rm_rf!(fixture.root) end)

    assert {:error, report} = WorkspaceSetup.run(fixture.worktree, fixture.job)
    assert report.state == "failed"
    assert report.script == "scripts/ptc/setup-worktree"
    assert report.source_sha == fixture.sha
    assert report.exit_status == 17
    assert report.output == "missing tool\n"
    assert report.error == :workspace_setup_failed
  end

  test "fails closed when setup changes tracked source" do
    fixture = workspace_fixture("printf 'changed\\n' > README.md\n")
    on_exit(fn -> File.rm_rf!(fixture.root) end)

    assert {:error, report} = WorkspaceSetup.run(fixture.worktree, fixture.job)
    assert report.state == "failed"
    assert report.error == :worktree_changed
    assert File.read!(Path.join(fixture.worktree, "README.md")) == "changed\n"
  end

  @tag nightly: false
  test "the contract accepts only one contained script path" do
    contract = %Contract{
      version: 1,
      bootstrap_command: "../outside",
      bootstrap_timeout_minutes: 1,
      before_publish_command: "./scripts/ci/pre-publication",
      verification_timeout_minutes: 1
    }

    assert {:error, :workspace_setup_script_escapes_worktree} =
             Contract.bootstrap_script(contract)

    assert {:error, :workspace_setup_must_be_one_script} =
             Contract.bootstrap_script(%{contract | bootstrap_command: "mix deps.get"})

    assert {:error, :workspace_setup_script_must_be_relative} =
             Contract.bootstrap_script(%{contract | bootstrap_command: ".//tmp/setup"})
  end

  test "the production runner enforces its timeout and output bound" do
    slow = workspace_fixture("sleep 2\n")
    on_exit(fn -> File.rm_rf!(slow.root) end)

    assert {:error, :workspace_setup_timeout} =
             WorkspaceSetup.Runner.run(
               slow.worktree,
               "scripts/ptc/setup-worktree",
               20
             )

    noisy = workspace_fixture("head -c 70000 /dev/zero | tr '\\000' x\n")
    on_exit(fn -> File.rm_rf!(noisy.root) end)

    assert {:ok, result} =
             WorkspaceSetup.Runner.run(
               noisy.worktree,
               "scripts/ptc/setup-worktree",
               5_000
             )

    assert result.exit_status == 0
    assert result.output_truncated
    assert byte_size(result.output) == 65_536
  end

  test "the production runner relies on the caller's verified source instead of probing Git" do
    root =
      Path.join(System.tmp_dir!(), "ptc-workspace-runner-#{System.unique_integer([:positive])}")

    script = Path.join(root, "setup")
    File.mkdir_p!(root)
    File.write!(script, "#!/bin/sh\nprintf 'ready\\n'\n")
    File.chmod!(script, 0o755)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, result} = WorkspaceSetup.Runner.run(root, "setup", 5_000)
    assert result.exit_status == 0
    assert result.output == "ready\n"
  end

  @tag nightly: false
  test "the production runner uses the bounded worker bootstrap bridge across OS identities" do
    assert {"/usr/bin/sudo",
            [
              "-n",
              "-H",
              "-u",
              "ptc-manager-worker",
              "--",
              "/usr/local/bin/ptc-manager-worker-bootstrap",
              "/srv/ptc_manager-worktrees/job-16",
              "scripts/ptc/bootstrap"
            ]} =
             WorkspaceSetup.Runner.command(
               "/srv/ptc_manager-worktrees/job-16",
               "scripts/ptc/bootstrap",
               "/srv/ptc_manager-worktrees/job-16/scripts/ptc/bootstrap",
               "ptc-manager-worker",
               "/usr/local/bin/ptc-manager-worker-bootstrap"
             )
  end

  defp workspace_fixture(script_body) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "ptc-workspace-setup-#{unique}")
    repository = Path.join(root, "repository")
    worktree = Path.join(root, "worktree")
    File.mkdir_p!(repository)

    git!(repository, ["init", "-b", "main"])
    git!(repository, ["config", "user.email", "test@example.com"])
    git!(repository, ["config", "user.name", "PtcManager Test"])
    File.mkdir_p!(Path.join(repository, "scripts/ptc"))
    File.write!(Path.join(repository, "README.md"), "fixture\n")
    File.write!(Path.join(repository, ".gitignore"), ".cache/\n")

    File.write!(
      Path.join(repository, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: ./scripts/ptc/setup-worktree
        timeout_minutes: 1
      verification:
        before_publish: ./scripts/ptc/setup-worktree
        timeout_minutes: 1
      """
    )

    setup = Path.join(repository, "scripts/ptc/setup-worktree")
    File.write!(setup, "#!/bin/sh\nset -eu\n" <> script_body)
    File.chmod!(setup, 0o755)
    git!(repository, ["add", "."])
    git!(repository, ["commit", "-m", "fixture"])

    job_id = unique
    branch = "ptc-manager/issue-10-job-#{job_id}"
    git!(repository, ["branch", branch])
    git!(repository, ["worktree", "add", worktree, branch])
    sha = git!(worktree, ["rev-parse", "HEAD"]) |> String.trim()

    %{
      root: root,
      repository: repository,
      worktree: worktree,
      sha: sha,
      job: %Job{id: job_id, issue_id: 10, branch_name: branch}
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
