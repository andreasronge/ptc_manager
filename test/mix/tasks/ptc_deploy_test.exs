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
    assert output =~ "maintenance mode"
    assert output =~ "read-only canary"
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

  test "remote deployment exposes the pinned Node runtime to managed agents" do
    script = File.read!(@remote_script)

    assert script =~ "node_version=22.23.2"
    assert script =~ "install_worker_node"
    assert script =~ "/opt/ptc-manager-node-${node_version}"
    assert script =~ "lib/node_modules/npm/bin/npm-cli.js"
    assert script =~ "lib/node_modules/npm/bin/npx-cli.js"
    assert script =~ "lib/node_modules/corepack/dist/corepack.js"
    assert script =~ "sudo -u ptc-manager-worker -H /usr/local/bin/node --version"
    assert script =~ "sudo -u ptc-manager-worker -H /usr/local/bin/npm --version"
  end

  test "remote deployment creates the coordinator-owned planning snapshot root" do
    script = File.read!(@remote_script)

    assert script =~ "sudo chmod 3770 /var/lib/ptc_manager-output"

    assert script =~
             "/var/lib/ptc_manager-output/planning-snapshots"

    assert script =~ "-m 2750"
  end

  test "remote deployment verifies maintenance health before crossing the canary effect boundary" do
    script = File.read!(@remote_script)

    assert script =~ "Environment=PTC_OPERATIONAL_MODE=maintenance"
    assert script =~ "/etc/systemd/system/ptc_manager.service.d/"
    assert script =~ "restore_preexisting_maintenance_override"
    assert script =~ ~s(health_url="http://127.0.0.1:${health_port}/health")
    assert script =~ "health_check maintenance"
    assert script =~ ".operational_mode == $mode"
    assert script =~ "deployment_phase=post_effect"
    assert script =~ "PtcManager.DeploymentCanary.run"
    assert script =~ "health_check canary"
    assert script =~ "PtcManager.DeploymentCanary.activate"
    assert script =~ "deployment_phase=complete"
    assert script =~ "remain in maintenance mode for forward repair"
    assert script =~ "deployment_phase=swapping_pre_effect"

    refute File.read!(@project_root <> "/deploy/ptc_manager.env.example") =~
             "PTC_OPERATIONAL_MODE="

    assert byte_index(script, "health_check maintenance") <
             byte_index(script, "deployment_phase=post_effect")

    assert byte_index(script, "deployment_phase=post_effect") <
             byte_index(script, "PtcManager.DeploymentCanary.run")

    assert byte_index(script, "health_check canary") <
             byte_index(script, "PtcManager.DeploymentCanary.activate")

    assert byte_index(script, "PtcManager.DeploymentCanary.activate") <
             byte_index(script, "deployment_phase=complete")

    assert byte_index(script, "deployment_phase=swapping_pre_effect") <
             byte_index(script, ~s(sudo mv "$application_dir" "$release_backup"))
  end

  defp jq_count(payload) do
    fixture = write_json_fixture(payload)
    {output, 0} = System.cmd("jq", ["-r", "-f", @agent_filter, fixture])
    output |> String.trim() |> String.to_integer()
  end

  defp write_json_fixture(payload) do
    write_fixture(Jason.encode!(payload), ".json")
  end

  defp byte_index(body, needle) do
    {index, _length} = :binary.match(body, needle)
    index
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
