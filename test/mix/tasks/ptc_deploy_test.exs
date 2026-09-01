defmodule Mix.Tasks.PtcDeployTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @project_root Path.expand("../../..", __DIR__)
  @local_script Path.join(@project_root, "deploy/deploy-herdr")
  @remote_script Path.join(@project_root, "deploy/remote-deploy-herdr")
  @worker_git Path.join(@project_root, "deploy/ptc-manager-worker-git")
  @failure_policy Path.join(@project_root, "deploy/deployment-failure-policy")
  @agent_filter Path.join(@project_root, "deploy/herdr-busy-agent-count.jq")
  @environment_file_parser Path.join(
                             @project_root,
                             "deploy/systemd-environment-file-paths.awk"
                           )

  test "deployment scripts have valid POSIX shell syntax" do
    for script <- [@local_script, @remote_script, @worker_git, @failure_policy] do
      assert {"", 0} = System.cmd("sh", ["-n", script], stderr_to_stdout: true)
    end
  end

  test "deployment failure policy classifies the effect boundary" do
    assert policy_for("swapping_pre_effect") == "restore_snapshot"
    assert policy_for("post_effect") == "preserve_current"
    assert policy_for("service_stopped") == "restart_existing"
    assert policy_for("complete") == "no_action"

    assert {_output, status} =
             System.cmd(@failure_policy, ["unknown"], stderr_to_stdout: true)

    assert status == 2
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

  test "remote deployment exposes mise for repository-owned worker setup" do
    script = File.read!(@remote_script)

    assert script =~ "worker_mise=/usr/local/bin/mise"
    assert script =~ "install_worker_mise"
    assert script =~ ~s(sudo install -o root -g root -m 0755 "$mise_binary" "$worker_mise")
    assert script =~ ~s(sudo -u ptc-manager-worker -H "$worker_mise" --version)

    assert byte_index(script, "install_worker_mise\ninstall_worker_node") <
             byte_index(script, "echo \"Building production release...\"")
  end

  test "remote production builds consume the persistent keyed workspace cache" do
    script = File.read!(@remote_script)

    assert script =~
             "production_workspace_cache=/home/agent/.cache/ptc-manager/workspaces"

    assert script =~
             ~s(env MIX_ENV=prod PTC_WORKSPACE_CACHE_ROOT="$production_workspace_cache" \\)

    assert script =~ "./scripts/ptc/bootstrap"

    refute script =~ "env MIX_ENV=prod mix deps.get"

    assert byte_index(script, "./scripts/ptc/bootstrap") <
             byte_index(script, "env MIX_ENV=prod mix compile")
  end

  test "remote deployment provisions and exercises the isolated gate toolchain" do
    script = File.read!(@remote_script)

    assert script =~ "install_gate_beam_toolchain"
    assert script =~ "verify_gate_contract"
    assert script =~ "gate_mise_root=/opt/ptc-manager-gate-mise"
    assert script =~ "MISE_DATA_DIR=\"$gate_mise_data\""
    assert script =~ "gate_erlang_dir=\"$gate_mise_data/installs/erlang/${erlang_version}\""
    assert script =~ "gate_elixir_dir=\"$gate_mise_data/installs/elixir/${elixir_version}\""
    assert script =~ "gate_mix_home=/opt/ptc-manager-gate-mix"
    assert script =~ "sudo -u ptc-manager-gate env -i"

    assert script =~
             "/bin/sh -c 'cd /var/lib/ptc_manager-gate && exec /usr/local/bin/mix --version'"

    assert script =~
             "/bin/sh -c 'cd /var/lib/ptc_manager-gate && exec /usr/local/bin/mix help hex'"

    assert script =~ "local.hex --force --if-missing"
    assert script =~ "local.rebar --force --if-missing"
    assert script =~ "gate toolchain symlink escapes its root-owned prefix"
    assert script =~ "sudo install -o root -g ptc-manager-repo -m 0640"
    assert script =~ "tar -xf \"$gate_source_archive\""
    assert script =~ "command -v python3"
    assert script =~ "./scripts/ptc/bootstrap && ./scripts/ci/pre-publication"
    assert script =~ "GIT_NO_REPLACE_OBJECTS=1"

    assert byte_index(script, "env MIX_ENV=prod mix release") <
             byte_index(script, "install_gate_beam_toolchain\nverify_gate_contract")

    assert byte_index(script, "install_gate_beam_toolchain\nverify_gate_contract") <
             byte_index(script, "echo \"Stopping service and backing up SQLite...\"")
  end

  test "remote deployment creates the coordinator-owned planning snapshot root" do
    script = File.read!(@remote_script)

    assert script =~ "sudo chmod 3770 /var/lib/ptc_manager-output"

    assert script =~
             "/var/lib/ptc_manager-output/planning-snapshots"

    assert script =~ "-m 2750"
  end

  test "remote deployment gives agents a narrow writable result exchange" do
    script = File.read!(@remote_script)

    assert script =~ "agent_result_dir=/var/lib/ptc_manager-worker/agent-results"
    assert script =~ "sudo chmod 0710 /var/lib/ptc_manager-worker"

    assert script =~
             ~s(sudo install -d -o ptc-manager -g ptc-manager-output -m 3770 "$agent_result_dir")

    assert script =~
             "Environment=PTC_AGENT_ACTION_OUTPUT_DIR=$agent_result_dir"

    assert script =~ "80-ptc-manager-agent-results.conf"

    assert File.read!(@project_root <> "/deploy/ptc_manager.env.example") =~
             "PTC_AGENT_ACTION_OUTPUT_DIR=/var/lib/ptc_manager-worker/agent-results"
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

  defp policy_for(phase) do
    {output, 0} = System.cmd(@failure_policy, [phase])
    String.trim(output)
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
