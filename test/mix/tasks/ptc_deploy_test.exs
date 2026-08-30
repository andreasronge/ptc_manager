defmodule Mix.Tasks.PtcDeployTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @project_root Path.expand("../../..", __DIR__)
  @local_script Path.join(@project_root, "deploy/deploy-herdr")
  @remote_script Path.join(@project_root, "deploy/remote-deploy-herdr")
  @worker_git Path.join(@project_root, "deploy/ptc-manager-worker-git")
  @agent_filter Path.join(@project_root, "deploy/herdr-busy-agent-count.jq")
  @environment_file_parser Path.join(
                             @project_root,
                             "deploy/systemd-environment-file-paths.awk"
                           )

  test "deployment scripts have valid POSIX shell syntax" do
    for script <- [@local_script, @remote_script, @worker_git] do
      assert {"", 0} = System.cmd("sh", ["-n", script], stderr_to_stdout: true)
    end
  end

  test "Mix task exposes the guarded deployment workflow" do
    Mix.Task.reenable("ptc.deploy")

    output =
      capture_io(fn ->
        assert :ok = Mix.Task.run("ptc.deploy", ["--help"])
      end)

    assert output =~ "Usage: mix ptc.deploy"
    assert output =~ "backs up the"
    assert output =~ "migrations"
  end

  test "busy-agent filter accepts every Herdr response envelope" do
    agent = %{"agent_status" => "working"}

    for payload <- [
          [agent],
          %{"agents" => [agent]},
          %{"result" => [agent]},
          %{"result" => %{"agents" => [agent]}}
        ] do
      assert jq_count(payload) == 1
    end
  end

  test "busy-agent filter understands state aliases and rejects unknown envelopes" do
    idle_and_terminal = [
      %{"agent_status" => "idle"},
      %{"status" => "completed"},
      %{"state" => "error"},
      %{"state" => "missing"}
    ]

    assert jq_count(%{"result" => %{"agents" => idle_and_terminal}}) == 0
    assert jq_count(%{"result" => %{"agents" => [%{"state" => "blocked"}]}}) == 1

    fixture = write_json_fixture(%{"unexpected" => []})
    {_output, status} = System.cmd("jq", ["-f", @agent_filter, fixture], stderr_to_stdout: true)
    assert status != 0
  end

  test "systemd environment-file parser preserves ordered drop-ins" do
    fixture =
      write_fixture(
        "/etc/ptc_manager/ptc_manager.env (ignore_errors=no) " <>
          "/etc/ptc_manager/override.env (ignore_errors=yes)\n" <>
          "/etc/ptc_manager/final.env (ignore_errors=no)\n"
      )

    assert {output, 0} = System.cmd("awk", ["-f", @environment_file_parser, fixture])

    assert String.split(output, "\n", trim: true) == [
             "/etc/ptc_manager/ptc_manager.env",
             "/etc/ptc_manager/override.env",
             "/etc/ptc_manager/final.env"
           ]
  end

  test "remote deployment removes shared write access from the worktree root" do
    script = File.read!(@remote_script)

    assert script =~ "ensure_private_worktree_root \"$worktree_root\""
    assert script =~ "sudo chmod 2750 \"$root\""
    assert script =~ "ptc-manager-worker:ptc-manager-repo"
    assert script =~ "worktree ancestor is writable by another identity"
    assert script =~ "worktree ancestor has an untrusted owner"
    assert script =~ "running_worktree_root"
  end

  defp jq_count(payload) do
    fixture = write_json_fixture(payload)
    {output, 0} = System.cmd("jq", ["-r", "-f", @agent_filter, fixture])
    output |> String.trim() |> String.to_integer()
  end

  defp write_json_fixture(payload) do
    write_fixture(Jason.encode!(payload), ".json")
  end

  defp write_fixture(contents, extension \\ ".txt") do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-deploy-fixture-#{System.unique_integer([:positive, :monotonic])}#{extension}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
