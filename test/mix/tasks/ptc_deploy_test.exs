defmodule Mix.Tasks.PtcDeployTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @project_root Path.expand("../../..", __DIR__)
  @local_script Path.join(@project_root, "deploy/deploy-herdr")
  @remote_script Path.join(@project_root, "deploy/remote-deploy-herdr")
  @worker_git Path.join(@project_root, "deploy/ptc-manager-worker-git")
  @worker_bootstrap Path.join(@project_root, "deploy/ptc-manager-worker-bootstrap")
  @claude_trust Path.join(@project_root, "deploy/ptc-manager-worker-claude-trust")
  @codex_arm Path.join(@project_root, "deploy/ptc-manager-worker-codex-arm")
  @gh_label Path.join(@project_root, "deploy/ptc-manager-worker-gh-label")
  @dropin_check Path.join(@project_root, "deploy/ptc-manager-check-access-dropin")
  @provision Path.join(@project_root, "deploy/ptc-manager-provision-repository")
  @failure_policy Path.join(@project_root, "deploy/deployment-failure-policy")
  @self_deploy_command Path.join(@project_root, "scripts/ptc/deploy")
  @self_deploy_runner Path.join(@project_root, "deploy/ptc-manager-self-deploy-runner")
  @operation_recovery Path.join(@project_root, "deploy/ptc-manager-operation-recover")
  @agent_filter Path.join(@project_root, "deploy/herdr-busy-agent-count.jq")
  @toolchain_manifest Path.join(@project_root, "deploy/toolchain-versions")
  @toolchain_reader Path.join(@project_root, "deploy/ptc-manager-toolchain-version")
  @environment_file_parser Path.join(
                             @project_root,
                             "deploy/systemd-environment-file-paths.awk"
                           )

  test "deployment scripts have valid POSIX shell syntax" do
    for script <- [
          @local_script,
          @remote_script,
          @worker_git,
          @worker_bootstrap,
          @claude_trust,
          @codex_arm,
          @gh_label,
          @dropin_check,
          @provision,
          @failure_policy,
          @self_deploy_command,
          @self_deploy_runner,
          @operation_recovery,
          @toolchain_reader
        ] do
      assert {"", 0} = System.cmd("sh", ["-n", script], stderr_to_stdout: true)
    end
  end

  test "the worker Claude trust helper records and removes one exact path" do
    home =
      Path.join(
        System.tmp_dir!(),
        "ptc-claude-trust-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    config = Path.join(home, ".claude.json")

    File.write!(
      config,
      Jason.encode!(%{
        "theme" => "dark",
        "projects" => %{"/other" => %{"hasTrustDialogAccepted" => true, "history" => []}}
      })
    )

    path = "/managed/planning-snapshots/ptc-manager-planning-a74-b5d9b142"

    assert {_output, 0} = helper(home, ["allow", path])
    trusted = Jason.decode!(File.read!(config))
    assert get_in(trusted, ["projects", path, "hasTrustDialogAccepted"]) == true
    assert get_in(trusted, ["projects", "/other", "hasTrustDialogAccepted"]) == true
    assert trusted["theme"] == "dark"

    assert {_output, 0} = helper(home, ["revoke", path])
    revoked = Jason.decode!(File.read!(config))
    refute Map.has_key?(revoked["projects"], path)
    assert get_in(revoked, ["projects", "/other", "history"]) == []

    assert {output, 2} = helper(home, ["allow", "relative/path"])
    assert output =~ "absolute"
    assert {output, 2} = helper(home, ["allow", "/managed/../escape"])
    assert output =~ "normalized"
    assert {output, 2} = helper(home, ["forget", path])
    assert output =~ "allow or revoke"
    assert Jason.decode!(File.read!(config)) == revoked
  end

  # The deployment builds installation paths out of what the reader prints, so
  # anything it cannot read exactly has to stop the deployment rather than yield
  # an empty version and link a path like /opt/ptc-manager-codex- into place.
  test "the toolchain reader prints one pinned version and refuses anything else" do
    assert {version, 0} = reader([@toolchain_manifest, "codex"])
    assert String.trim(version) == Map.fetch!(PtcManager.Toolchain.pinned(), "codex")

    assert {output, 2} = reader([@toolchain_manifest, "vim"])
    assert output =~ "pins no version for vim"

    assert {output, 2} = reader([@toolchain_manifest, "Codex"])
    assert output =~ "not a lowercase word"

    assert {output, 2} = reader(["/nonexistent/toolchain-versions", "codex"])
    assert output =~ "manifest is missing"

    manifest =
      Path.join(
        System.tmp_dir!(),
        "ptc-toolchain-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(manifest) end)

    File.write!(manifest, "codex=0.1.0\ncodex=0.2.0\n")
    assert {output, 2} = reader([manifest, "codex"])
    assert output =~ "pins codex more than once"

    # A line the reader cannot read stops the deployment even when the key it
    # was asked for is pinned elsewhere in the file. Skipping it would leave the
    # previous version installed while the edit looks applied.
    File.write!(manifest, "codex=0.1.0\ncodex=\n")
    assert {output, 2} = reader([manifest, "codex"])
    assert output =~ "line 2 is not a pinned version"

    File.write!(manifest, "codex = 0.1.0\n")
    assert {output, 2} = reader([manifest, "codex"])
    assert output =~ "line 1 is not a pinned version"

    File.write!(manifest, "codex=$(id -u)\nherdr=0.8.2\n")
    assert {output, 2} = reader([manifest, "herdr"])
    assert output =~ "line 1 is not a pinned version"

    File.write!(manifest, "# only a comment\n\n")
    assert {output, 2} = reader([manifest, "codex"])
    assert output =~ "pins no version for codex"
  end

  # The version a program reports is the program's own claim, so a download
  # nobody hashed can pass a version check by printing the expected string.
  test "the deployment verifies a pinned digest for every download it does not take from npm" do
    script = File.read!(@remote_script)

    for digest <- ~w(cursor_agent_sha256 herdr_sha256 mise_sha256) do
      assert script =~ ~s|!= "$#{digest}"|, digest
    end

    # Cursor's archive is proven before anything is unpacked from it.
    assert byte_index(script, ~s|!= "$cursor_agent_sha256"|) <
             byte_index(script, ~s|tar --strip-components=1 -xzf "$cursor_archive"|)

    # An executable an interrupted deployment left at the pinned path is what a
    # later restart would link, so it is proven on every run, not only on the
    # run that downloaded it.
    assert script =~ ~s|sudo sha256sum "$worker_herdr_dir/herdr"|
    assert script =~ ~s|sudo sha256sum "$worker_mise_dir/mise"|

    # An unpacked tree cannot be hashed back into its archive, so the digest
    # that proved it stays beside it and a tree without one is replaced.
    assert script =~ ~s|.ptc-manager-archive-sha256|
    assert script =~ ~s|sudo rm -rf -- "$worker_cursor_agent_dir"|
  end

  # The Herdr link moves during the stopped window, before the release swap. A
  # deployment that then goes back to the previous release has to go back to the
  # Herdr that release was built against, or an old coordinator is left speaking
  # to a server whose protocol it does not expect.
  test "a deployment that restores the previous release restores its Herdr" do
    script = File.read!(@remote_script)

    assert script =~ ~s|sudo cp -a "$worker_herdr" "$herdr_link_backup"|
    assert script =~ "restore_worker_herdr"

    # Both failure paths that bring the previous release back call it, and the
    # one that keeps the new release in maintenance does not.
    assert byte_index(script, "restore_worker_herdr || rollback_status=1") <
             byte_index(script, "restore_preexisting_maintenance_override || rollback_status=1")

    assert length(String.split(script, "restore_worker_herdr")) == 4

    # The function is always called where its result is tested, which switches
    # set -e off for its body, so a failed step has to be reported rather than
    # covered by a final command that cannot fail.
    assert script =~ "return \"$restore_status\""
    refute script =~ "sudo systemctl restart ptc_manager-herdr || true"

    # A restoration that failed leaves the backup as the only copy of the Herdr
    # the running release expects, so cleanup must not take it away.
    assert script =~ "herdr_link_backup_retained=true"
    assert script =~ ~s|if [ "$herdr_link_backup_retained" != true ]; then|
  end

  # The deployment and the release read the same manifest, so a pin one of them
  # needs and the other does not know about is a deployment that fails on the
  # machine or a release that compiled against a manifest it cannot use.
  test "the deployment reads exactly the pins the release requires" do
    script = File.read!(@remote_script)

    read =
      ~r/"\$toolchain_reader" "\$toolchain_manifest" ([a-z0-9_]+)/
      |> Regex.scan(script)
      |> Enum.map(fn [_line, key] -> key end)
      |> Enum.sort()

    assert read == Enum.sort(PtcManager.Toolchain.required_pins())
  end

  # A version written twice drifts. The manifest is the only place one belongs,
  # and the release reads the same file the deployment does.
  test "the deployment script writes no version of its own" do
    script = File.read!(@remote_script)

    for {program, version} <- PtcManager.Toolchain.pinned() do
      refute String.contains?(script, version),
             "deploy/remote-deploy-herdr repeats the #{program} version #{version}"
    end

    assert script =~ "read_pinned_versions"
  end

  # `sudo mktemp -d` creates the staging root 0700 and `cp -a` preserves the
  # modes of what it copies, not of the root it copies into. A pinned tree left
  # 0700 belongs to root alone: the worker cannot run the program linked inside
  # it, and the deploying user's own glob over the tree expands to nothing, which
  # the deployment then reports as a malformed package rather than as the
  # permission problem it is. Every staged tree therefore goes through the one
  # helper that both owns and opens it.
  test "every staged /opt tree is made traversable before it is moved into place" do
    script = File.read!(@remote_script)

    staged =
      ~r/\$\(sudo mktemp -d "\$?\{?(?:\/opt\/)?[^"]*"\)/
      |> Regex.scan(script)
      |> length()

    claimed =
      ~r/^ *root_own_pinned_tree "\$[a-z_]+"$/m
      |> Regex.scan(script)
      |> length()

    assert staged > 0

    assert claimed == staged,
           "#{staged} staged /opt trees but #{claimed} go through root_own_pinned_tree"

    refute script =~ ~r/^ *sudo chown -R root:root "\$[a-z_]*staging"/m,
           "a staging tree is owned without being made traversable"

    assert script =~
             ~r/root_own_pinned_tree\(\) \{\n  sudo chown -R root:root "\$1"\n  sudo chmod 0755 "\$1"\n\}/
  end

  defp reader(args) do
    System.cmd("sh", [@toolchain_reader | args], stderr_to_stdout: true)
  end

  defp helper(home, args) do
    System.cmd("sh", [@claude_trust | args], env: [{"HOME", home}], stderr_to_stdout: true)
  end

  # Herdr restores a pane after a server restart by running `codex resume` with
  # no arguments, so the approval bypass PtcManager passes at `herdr agent start`
  # is gone and the resumed agent stops at a prompt nobody answers. The same
  # policy recorded in config.toml survives that restore.
  test "the worker Codex arming helper records and removes the managed policy" do
    home =
      Path.join(
        System.tmp_dir!(),
        "ptc-codex-arm-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(home, ".codex"))
    on_exit(fn -> File.rm_rf!(home) end)
    config = Path.join(home, ".codex/config.toml")

    original =
      "[features]\nhooks = true\n\n[projects.\"/srv/ptc_runner\"]\ntrust_level = \"trusted\"\n"

    File.write!(config, original)

    assert {_output, 0} = arming(home, ["arm"])
    armed = File.read!(config)
    assert armed =~ ~s(approval_policy = "never")
    assert armed =~ ~s(sandbox_mode = "danger-full-access")
    assert armed =~ ~s([projects."/srv/ptc_runner"])

    assert {_output, 0} = arming(home, ["arm"])
    assert File.read!(config) == armed

    assert {_output, 0} = arming(home, ["disarm"])
    assert File.read!(config) == original

    assert {output, 2} = arming(home, ["forget"])
    assert output =~ "arm or disarm"

    File.write!(config, ~s(approval_policy = "on-request"\n))
    assert {output, 2} = arming(home, ["arm"])
    assert output =~ "already sets approval_policy"
    assert File.read!(config) == ~s(approval_policy = "on-request"\n)
  end

  # The drop-in is installed into a unit that runs as root, and systemd only
  # warns about a directive it cannot parse, so the generated content is the
  # only thing that can be checked before it lands.
  test "the access drop-in check accepts generated grants and rejects anything else" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ptc-dropin-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    header = "# Generated by the PtcManager deployment. Do not edit.\n[Service]\n"

    write = fn name, body ->
      path = Path.join(directory, name)
      File.write!(path, body)
      System.cmd("sh", [@dropin_check, path], stderr_to_stdout: true)
    end

    assert {"", 0} =
             write.(
               "good.conf",
               header <>
                 "ReadWritePaths=-/srv/ptc_runner/.git\nReadWritePaths=-/srv/ptc-fs-mcp/.git\n"
             )

    assert {output, 1} =
             write.("injected.conf", header <> "ReadWritePaths=-/srv/ok\nExecStart=/bin/evil\n")

    assert output =~ "unexpected line"

    assert {output, 1} = write.("traversal.conf", header <> "ReadWritePaths=-/srv/../etc\n")
    assert output =~ "unnormalized path"

    assert {output, 1} = write.("outside.conf", header <> "ReadWritePaths=-/etc/shadow\n")
    assert output =~ "unexpected line"

    assert {output, 1} = write.("empty.conf", header)
    assert output =~ "grants nothing"

    assert {output, 1} = write.("headerless.conf", "ReadWritePaths=-/srv/ok\n")
    assert output =~ "generated header"
  end

  defp arming(home, args) do
    System.cmd("sh", [@codex_arm | args],
      env: [{"HOME", home}, {"CODEX_HOME", nil}],
      stderr_to_stdout: true
    )
  end

  test "self-deploy command runs from its immutable archive without a Git checkout" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-self-deploy-command-#{System.unique_integer([:positive, :monotonic])}"
      )

    source = Path.join(root, "source")

    archive = "/tmp/ptc-manager-self-command-#{System.unique_integer([:positive])}.tar"

    File.mkdir_p!(Path.join(source, "deploy"))

    File.write!(
      Path.join(source, "deploy/remote-deploy-herdr"),
      "#!/bin/sh\nprintf '%s\\n' \"$1|$2|$3|$4\"\n"
    )

    File.write!(Path.join(source, "deploy/deployment-failure-policy"), "#!/bin/sh\nexit 0\n")
    # Match the repository archive layout exactly. GNU tar preserves the leading
    # "./" when archiving ".", while git archive and bsdtar expose "deploy/...".
    assert {"", 0} = System.cmd("tar", ["-cf", archive, "-C", source, "deploy"])

    sha = String.duplicate("a", 40)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(archive)
    end)

    assert {output, 0} =
             System.cmd(@self_deploy_command, [],
               cd: root,
               env: [
                 {"PTC_DEPLOY_SHA", sha},
                 {"PTC_DEPLOY_SOURCE_ARCHIVE", archive},
                 {"PTC_DEPLOYMENT_ID", "42"}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "|#{archive}|/tmp/ptc-manager-failure-policy-"
    assert output =~ "|#{sha}"
  end

  test "remote deployment installs the bounded worker bootstrap bridge" do
    script = File.read!(@remote_script)
    sudoers = File.read!(Path.join(@project_root, "deploy/ptc_manager.sudoers"))
    wrapper = File.read!(@worker_bootstrap)

    assert script =~ "deploy/ptc-manager-worker-bootstrap"
    assert script =~ "/usr/local/bin/ptc-manager-worker-bootstrap"
    assert sudoers =~ "/usr/local/bin/ptc-manager-worker-bootstrap"
    assert wrapper =~ "worktree_root=/srv/ptc_manager-worktrees"
    assert wrapper =~ "worktree is outside the managed root"
    assert wrapper =~ "script is outside the worktree"
  end

  test "remote deployment installs the out-of-process self-deploy bridge" do
    script = File.read!(@remote_script)
    sudoers = File.read!(Path.join(@project_root, "deploy/ptc_manager.sudoers"))
    unit = File.read!(Path.join(@project_root, "deploy/ptc_manager-self-deploy.service"))

    assert script =~ "deploy/ptc-manager-self-deploy-runner"
    assert script =~ "/usr/local/bin/ptc-manager-self-deploy-runner"
    assert script =~ "/etc/systemd/system/ptc-manager-self-deploy.service"
    assert script =~ "printf '%s\\n' \"$source_commit_sha\" >\"$new_release/RELEASE_SHA\""
    assert script =~ "PtcManager.OperationalMode.enter_draining()"
    assert sudoers =~ "/bin/systemctl start --no-block ptc-manager-self-deploy.service"
    assert unit =~ "Type=oneshot"
    assert unit =~ "User=agent"

    runner = File.read!(@self_deploy_runner)
    assert runner =~ "*) command_path=$command ;;"
    assert runner =~ ~s(tar -xOf "$archive" "$command_path")
  end

  test "remote deployment installs the fenced operation recovery helper" do
    script = File.read!(@remote_script)
    sudoers = File.read!(Path.join(@project_root, "deploy/ptc_manager.sudoers"))
    helper = File.read!(@operation_recovery)

    assert script =~ "deploy/ptc-manager-operation-recover"
    assert script =~ "/usr/local/bin/ptc-manager-operation-recover"
    assert sudoers =~ "/usr/local/bin/ptc-manager-operation-recover *"
    assert helper =~ "operation cgroup does not match its fenced identity"
    assert helper =~ "cgroup.kill"
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

  test "direct and managed deployments assign operational-mode ownership explicitly" do
    local = File.read!(@local_script)
    remote = File.read!(@remote_script)
    managed = File.read!(@self_deploy_command)

    assert local =~ "'$commit_sha' direct"
    assert managed =~ "\"$requested_sha\" managed"
    assert remote =~ "if [ \"$activation_owner\" = managed ]"
    assert remote =~ "OperationalMode.enter_draining()"
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

    assert script =~ ~s|node_version=$("$toolchain_reader" "$toolchain_manifest" node)|
    assert script =~ "install_worker_node"
    assert script =~ "/opt/ptc-manager-node-${node_version}"
    assert script =~ "lib/node_modules/npm/bin/npm-cli.js"
    assert script =~ "lib/node_modules/npm/bin/npx-cli.js"
    assert script =~ "lib/node_modules/corepack/dist/corepack.js"
    assert script =~ "sudo -u ptc-manager-worker -H /usr/local/bin/node --version"
    assert script =~ "sudo -u ptc-manager-worker -H /usr/local/bin/npm --version"
  end

  test "remote deployment installs every agent CLI at the version it pins" do
    script = File.read!(@remote_script)

    assert script =~ "install_worker_codex"
    assert script =~ "install_worker_claude_code"
    assert script =~ "install_worker_cursor_agent"
    assert script =~ "install_worker_herdr"

    # An unverified download never becomes the program on the worker's PATH.
    assert script =~ ~s|!= "codex-cli $codex_version"|
    assert script =~ ~s|!= "$claude_code_version (Claude Code)"|
    assert script =~ ~s|!= "$cursor_agent_version"|
    assert script =~ ~s|!= "$herdr_sha256"|
    assert script =~ ~s|!= "herdr $herdr_version"|

    # The Cursor CLI no longer comes from a per-user installation, and the
    # hand-placed trees the pinned ones replace are removed.
    refute script =~ "/home/agent/.local/share/cursor-agent"
    assert script =~ "sudo rm -rf -- /opt/codex /opt/ptc-manager-cursor-agent"

    # A client whose protocol does not match the running server breaks the
    # coordinator, so Herdr's link moves in the one step that restarts it.
    assert script =~
             ~s|sudo ln -sfn "$worker_herdr_dir/herdr" "$worker_herdr"\n    sudo systemctl restart ptc_manager-herdr|

    # A deployment is the only thing that moves the link, so the deferred branch
    # must not tell a maintainer that restarting the service by hand will do it.
    assert script =~ "a deployment is what moves the link"
    refute script =~ "Restart it when none is retained"

    assert String.split(script, ~s|"$worker_herdr_dir/herdr" "$worker_herdr"|) |> length() == 2
  end

  test "remote deployment exposes mise for repository-owned worker setup" do
    script = File.read!(@remote_script)

    assert script =~ "worker_mise=/usr/local/bin/mise"
    assert script =~ "install_worker_mise"
    assert script =~ ~s|sudo ln -sfn "$worker_mise_dir/mise" "$worker_mise"|
    assert script =~ ~s(sudo -u ptc-manager-worker -H "$worker_mise" --version)

    # The worker's mise is a pinned program, not a copy of whatever the
    # deploying user happens to have installed, and it is the only mise the
    # deployment runs: the user-owned one was executed through sudo to provision
    # the gate, which made an unverified binary root on this machine.
    refute script =~ "mise_binary"
    refute script =~ "/home/agent/.local/bin/mise"
    assert script =~ ~s|"$worker_mise" install "node@${node_version}"|

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

  test "remote deployment provisions the isolated publication-gate toolchain without rerunning tests" do
    script = File.read!(@remote_script)

    assert script =~ "install_gate_beam_toolchain"
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

    # Mix installs a mismatched --sha512 once --force is given, so the gate
    # hashes the Rebar it received instead of asking mix to check it.
    assert script =~ ~s|gate_mix local.hex "$hex_version" --force|
    assert script =~ "gate_mix local.rebar --force"
    assert script =~ ~s|!= "$rebar3_sha512"|
    assert script =~ "gate_rebar_digest"

    # Mix keeps one Rebar per Elixir series, so the digest names the series this
    # revision pins and copies from older ones are removed rather than left to
    # answer for a series that has none.
    assert script =~ "gate_rebar_series"
    assert script =~ ~s|! -name "$rebar_series"|
    refute script =~ "local.hex --force --if-missing"
    refute script =~ "local.rebar --force --if-missing"
    refute script =~ "local.rebar --force --sha512"
    assert script =~ "gate toolchain symlink escapes its root-owned prefix"
    refute script =~ "verify_gate_contract"
    refute script =~ "./scripts/ci/pre-publication"
    refute script =~ "deployment-contract."

    toolchain_install = "env MIX_ENV=prod mix release\ninstall_gate_beam_toolchain"

    assert byte_index(script, toolchain_install) <
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
             "PTC_AGENT_ACTION_OUTPUT_DIR=$agent_result_dir"

    assert script =~ "EnvironmentFile=$agent_result_env"
    assert script =~ "zz-ptc-manager-agent-results.conf"

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

  @tag :nightly
  test "the label wrapper refuses everything but one safe issue edit" do
    directory = Path.join(System.tmp_dir!(), "ptc-gh-label-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "usr/bin"))
    recording = Path.join(directory, "calls")
    fake_gh = Path.join(directory, "usr/bin/gh")

    File.write!(fake_gh, """
    #!/bin/sh
    printf '%s\n' "$*" >> #{recording}
    """)

    File.chmod!(fake_gh, 0o755)
    on_exit(fn -> File.rm_rf(directory) end)

    # The wrapper hard-codes /usr/bin/gh, so run it through a shell that maps
    # that path onto the fake one rather than editing the shipped script.
    run = fn args ->
      script = File.read!(@gh_label) |> String.replace("/usr/bin/gh", fake_gh)
      path = Path.join(directory, "wrapper")
      File.write!(path, script)
      File.chmod!(path, 0o755)
      System.cmd(path, args, stderr_to_stdout: true)
    end

    assert {_output, 0} = run.(["owner/repo", "1701", "add", "wait"])
    assert File.read!(recording) =~ "issue edit 1701 --repo owner/repo --add-label wait"

    assert {_output, 64} = run.(["owner/repo", "1701", "merge", "wait"])
    assert {_output, 64} = run.(["owner/repo", "1701", "add", "ptc:ready"])
    assert {_output, 64} = run.(["owner/repo", "1701", "add", "PTC:ready"])
    assert {_output, 64} = run.(["owner/repo", "1701", "remove", "Ptc:Blocked"])
    assert {_output, 64} = run.(["owner/repo; rm -rf /", "1701", "add", "wait"])
    assert {_output, 64} = run.(["owner/repo", "not-a-number", "add", "wait"])
    assert {_output, 64} = run.(["owner/repo", "1701", "add", "$(whoami)"])
    assert File.read!(recording) |> String.split("\n", trim: true) |> length() == 1
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
