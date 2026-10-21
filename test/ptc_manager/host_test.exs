defmodule PtcManager.HostTest do
  use ExUnit.Case, async: false

  alias PtcManager.Host

  setup do
    keys = [:host_profile, :herdr_run_as_user, :resource_operation_cgroups, :tool_probe_script]
    previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_manager, key, value)
        {key, :error} -> Application.delete_env(:ptc_manager, key)
      end)
    end)
  end

  defp host(profile, user, cgroups \\ false) do
    Application.put_env(:ptc_manager, :host_profile, profile)
    Application.put_env(:ptc_manager, :herdr_run_as_user, user)
    Application.put_env(:ptc_manager, :resource_operation_cgroups, cgroups)
  end

  test "each profile answers every platform question" do
    host(:linux, "ptc-worker", true)
    assert Host.agent_identity() == {:separate, "ptc-worker"}
    assert Host.containment() == :cgroup
    assert Host.uncertain_operation_policy() == :escalate
    refute Host.check_remaining_processes?()
    assert Host.service_manager() == :systemd
    assert Host.trusted_ancestor_owners(501) == [0]

    host(:linux, nil, false)
    assert Host.agent_identity() == :service_account
    assert Host.containment() == :none
    # Linux without cgroups keeps today's escalation and normal finishes.
    assert Host.uncertain_operation_policy() == :escalate
    refute Host.check_remaining_processes?()
    assert Host.trusted_ancestor_owners(501) == [0, 501]

    host(:macos, "")
    assert Host.agent_identity() == :service_account
    assert Host.containment() == :none
    assert Host.uncertain_operation_policy() == :fence
    assert Host.check_remaining_processes?()
    assert Host.service_manager() == :launchd

    host(:development, nil)
    assert Host.uncertain_operation_policy() == :fence
    assert Host.check_remaining_processes?()
    assert Host.service_manager() == :none

    host(:development, "ptc-worker")
    assert Host.separate_agent_account?()
  end

  test "Linux separate-account helper commands are unchanged" do
    host(:linux, "ptc-worker", true)
    Application.delete_env(:ptc_manager, :tool_probe_script)
    sudo = ["/usr/bin/sudo", "-n", "-H", "-u"]

    assert {"/usr/bin/sudo", args} = Host.agent_command("/usr/local/bin/x", ["a"])
    assert ["/usr/bin/sudo" | args] == sudo ++ ["ptc-worker", "--", "/usr/local/bin/x", "a"]

    expected = %{
      worktree_cleanup: ["ptc-worker", "--", "/usr/local/bin/ptc-manager-worker-worktree-cleanup"],
      worktree_preserve: [
        "ptc-worker",
        "--",
        "/usr/local/bin/ptc-manager-worker-worktree-preserve"
      ],
      worktree_seal: ["root", "--", "/usr/local/bin/ptc-manager-worker-worktree-seal"],
      tool_probe: ["ptc-worker", "--", "/usr/local/bin/ptc-manager-tool-probe"]
    }

    for {key, prefix} <- expected do
      assert {"/usr/bin/sudo", args} = Host.helper_command(key, ["one", "two"])
      assert ["/usr/bin/sudo" | args] == sudo ++ prefix ++ ["one", "two"]
    end

    assert PtcManager.Herdr.Command.command("herdr", ["pane", "list"]) ==
             {"/usr/bin/sudo",
              [
                "-n",
                "-H",
                "-u",
                "ptc-worker",
                "--",
                "herdr",
                "--session",
                "default",
                "pane",
                "list"
              ]}
  end

  test "service-account helpers run the packaged scripts directly" do
    host(:macos, nil)

    for {key, script} <- [
          worktree_cleanup: "worktree_cleanup.py",
          worktree_preserve: "worktree_preserve.py",
          worktree_seal: "worktree_seal.py",
          tool_probe: "tool_probe.py"
        ] do
      assert Host.helper_command(key, ["one"]) ==
               {"/usr/bin/python3",
                ["-I", Application.app_dir(:ptc_manager, Path.join("priv", script)), "one"]}
    end

    assert Host.agent_command("git", ["status"]) == {"git", ["status"]}
  end

  test "only the host module reads the agent account, the OS type or the service root" do
    forbidden = [":herdr_run_as_user", ":os.type()", "PTC_MACOS_SERVICE_ROOT"]

    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,exs}"),
          path != "lib/ptc_manager/host.ex",
          source = File.read!(path),
          read <- forbidden,
          String.contains?(source, read),
          do: {path, read}

    assert offenders == []
  end
end
