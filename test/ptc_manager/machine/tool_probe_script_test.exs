defmodule PtcManager.Machine.ToolProbeScriptTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../../..", __DIR__)
  @script Path.join(@project_root, "priv/tool_probe.py")

  setup do
    root = Path.join(System.tmp_dir!(), "ptc-tool-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "runs each probe as argv without a shell and records raw results", %{root: root} do
    tool = executable(root, "tool", ~s(echo "tool 1.2.3"; echo warn >&2))
    failing = executable(root, "failing", "echo nope >&2; exit 3")
    marker = Path.join(root, "expanded")

    catalog =
      catalog(root, [
        %{name: "tool", argv: [tool]},
        %{name: "failing", argv: [failing]},
        %{name: "absent", argv: [Path.join(root, "absent")]},
        # A shell would expand this and create the marker; argv must not.
        %{name: "literal", argv: ["/bin/echo", "$(touch #{marker})"]}
      ])

    output = Path.join(root, "tool-inventory-pane.json")
    assert {_out, 0} = System.cmd("/usr/bin/python3", ["-I", @script, "pane", catalog, output])

    snapshot = output |> File.read!() |> Jason.decode!()
    assert snapshot["context"] == "pane"
    assert snapshot["os"] in ["linux", "darwin"]
    assert is_integer(snapshot["cpu_count"])
    assert {:ok, _at, 0} = DateTime.from_iso8601(snapshot["captured_at"])

    probes = Map.new(snapshot["probes"], &{&1["name"], &1})
    assert probes["tool"]["exit_status"] == 0
    assert probes["tool"]["stdout"] == "tool 1.2.3\n"
    assert probes["tool"]["stderr"] == "warn\n"
    assert probes["failing"]["exit_status"] == 3
    assert probes["absent"]["error"] == "not_found"
    assert probes["literal"]["stdout"] =~ "$(touch"
    refute File.exists?(marker)
    assert File.stat!(output).mode |> Bitwise.band(0o777) == 0o640
  end

  test "caps output and refuses an oversized catalog", %{root: root} do
    # Twenty megabytes on each stream; only the first 4 KiB is ever kept.
    noisy =
      executable(
        root,
        "noisy",
        ~s(head -c 20000000 /dev/zero | tr '\\0' x; head -c 20000000 /dev/zero >&2)
      )

    catalog = catalog(root, [%{name: "noisy", argv: [noisy]}])

    assert {json, 0} = System.cmd("/usr/bin/python3", ["-I", @script, "setup", catalog])
    [probe] = Jason.decode!(json)["probes"]
    assert byte_size(probe["stdout"]) == 4096
    assert byte_size(probe["stderr"]) == 4096
    assert probe["exit_status"] == 0

    oversized = catalog(root, for(index <- 1..25, do: %{name: "t#{index}", argv: ["true"]}))

    assert {_out, 2} =
             System.cmd("/usr/bin/python3", ["-I", @script, "pane", oversized],
               stderr_to_stdout: true
             )

    assert {_out, 2} =
             System.cmd("/usr/bin/python3", ["-I", @script, "other", catalog],
               stderr_to_stdout: true
             )
  end

  @tag :nightly
  test "a probe that hangs is killed and the snapshot is still written", %{root: root} do
    hang = executable(root, "hang", "sleep 30")
    catalog = catalog(root, [%{name: "hang", argv: [hang]}, %{name: "true", argv: ["true"]}])

    assert {json, 0} = System.cmd("/usr/bin/python3", ["-I", @script, "pane", catalog])
    probes = Map.new(Jason.decode!(json)["probes"], &{&1["name"], &1})
    assert probes["hang"]["timed_out"]
    assert probes["true"]["exit_status"] == 0
  end

  @tag :nightly
  test "descendants that outlive their probe are killed", %{root: root} do
    holding = Path.join(root, "holding-pid")
    detached = Path.join(root, "detached-pid")

    wrapper =
      executable(
        root,
        "wrapper",
        "sleep 30 & echo $! > #{holding}; sleep 30 >/dev/null 2>&1 & echo $! > #{detached}; echo started"
      )

    catalog = catalog(root, [%{name: "wrapper", argv: [wrapper]}])

    assert {json, 0} = System.cmd("/usr/bin/python3", ["-I", @script, "pane", catalog])
    [probe] = Jason.decode!(json)["probes"]
    assert probe["exit_status"] == 0
    assert probe["stdout"] == "started\n"

    for marker <- [holding, detached] do
      pid = marker |> File.read!() |> String.trim()
      assert {_out, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0, "the descendant #{pid} is still running"
    end
  end

  describe "the agent-pane probe unit" do
    test "runs with the Herdr service's identity, environment, and sandbox" do
      herdr = unit("deploy/ptc_manager-herdr.service")
      probe = unit("deploy/ptc_manager-tool-probe.service")

      for directive <-
            ~w(User Group SupplementaryGroups WorkingDirectory EnvironmentFile PrivateTmp ProtectHome ProtectSystem ReadWritePaths) do
        assert Map.fetch!(herdr, directive) == Map.fetch!(probe, directive),
               "#{directive} differs between the Herdr service and the tool-probe unit"
      end

      # Every other Herdr directive is about the long-running server, not its environment.
      server_only = ~w(Delegate Restart RestartSec TimeoutStopSec)
      assert (Map.keys(herdr) -- server_only) -- Map.keys(probe) == []
    end

    test "is installed with its timer and started only through its sudoers rule" do
      script = File.read!(Path.join(@project_root, "deploy/remote-deploy-herdr"))
      sudoers = File.read!(Path.join(@project_root, "deploy/ptc_manager.sudoers"))

      for source <-
            ~w(priv/tool_probe.py deploy/ptc_manager-tool-probe.service deploy/ptc_manager-tool-probe.timer) do
        assert script =~ ~s(tar -xOf "$source_archive" #{source})
      end

      assert script =~ "/usr/local/bin/ptc-manager-tool-probe"
      assert script =~ "/etc/systemd/system/ptc_manager-tool-probe.timer"
      assert script =~ "systemctl enable --now ptc_manager-tool-probe.timer"

      assert sudoers =~
               "ptc-manager ALL=(root) NOPASSWD: /bin/systemctl start --no-block ptc_manager-tool-probe.service"

      assert sudoers =~
               "ptc-manager ALL=(ptc-manager-worker) NOPASSWD: /usr/local/bin/ptc-manager-tool-probe"

      probe = unit("deploy/ptc_manager-tool-probe.service")
      assert probe["ExecStart"] =~ "/usr/local/bin/ptc-manager-tool-probe pane "
    end
  end

  defp unit(path) do
    @project_root
    |> Path.join(path)
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "#") or not String.contains?(&1, "=")))
    |> Enum.reduce(%{}, fn line, directives ->
      [key, value] = String.split(line, "=", parts: 2)
      Map.update(directives, key, value, &(&1 <> " " <> value))
    end)
    |> Map.drop(~w(Description After Wants WantedBy))
  end

  defp catalog(root, probes) do
    path = Path.join(root, "catalog-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{probes: probes}))
    path
  end

  defp executable(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end
end
