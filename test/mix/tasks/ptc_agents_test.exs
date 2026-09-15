defmodule Mix.Tasks.Ptc.AgentsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Ptc.Agents
  alias PtcManager.Toolchain

  @project_root Path.expand("../../..", __DIR__)
  @report Path.join(@project_root, "deploy/agent-report")
  @probe Path.join(@project_root, "deploy/ptc-manager-agent-probe")

  test "both report scripts parse as POSIX shell" do
    for script <- [@report, @probe] do
      assert {"", 0} = System.cmd("sh", ["-n", script], stderr_to_stdout: true)
    end
  end

  test "probe tests the worker-only Herdr link without requiring deploy-user execute access" do
    probe = File.read!(@probe)

    assert probe =~ "herdr_session_file=/etc/ptc_manager/herdr-bridge-session"
    assert probe =~ "if [ -e /usr/local/bin/herdr ]; then"
    refute probe =~ "if [ -x /usr/local/bin/herdr ]; then"
  end

  # Asking for help is not a failure. `mix ptc.deploy` already prints its usage
  # on stdout and succeeds, and a Mix task that raises over `--help` reports the
  # answer as an error.
  test "asking for help succeeds and a usage error does not" do
    assert {help, 0} = System.cmd("sh", [@report, "--help"], stderr_to_stdout: true)
    assert help =~ "Usage: mix ptc.agents"

    assert {refused, 2} = System.cmd("sh", [@report, "--nope"], stderr_to_stdout: true)
    assert refused =~ "unknown argument: --nope"
  end

  # The target reaches ssh as an argument, so it is checked before it is used.
  test "a target carrying anything but host characters is refused" do
    assert {output, 2} =
             System.cmd("sh", [@report, "--target", "evil;rm -rf /"], stderr_to_stdout: true)

    assert output =~ "invalid SSH target"
  end

  test "a record's trailing fields survive parsing" do
    assert [{"agent", "codex", ["codex-cli 1.2.3", "Logged in", "/opt/x"]}] =
             Agents.parse("agent\tcodex\tcodex-cli 1.2.3\tLogged in\t/opt/x\n")
  end

  test "a line without a kind and a key is not a record" do
    assert [] = Agents.parse("\nnot-a-record\n")
  end

  # The pinned version has to appear in what the program printed. Each CLI
  # decorates it differently, so this is the only comparison that holds for all
  # three, and a version that does not appear is drift however it is decorated.
  test "a reported version carrying the pinned one matches" do
    pinned = Map.fetch!(Toolchain.pinned(), "codex")

    output = render([{"agent", "codex", ["codex-cli #{pinned}", "Logged in", "/opt/x"]}])

    assert output =~ "#{pinned} (matches)"
    refute output =~ "DRIFT"
  end

  test "a reported version that is not the pinned one is drift" do
    output = render([{"agent", "codex", ["codex-cli 0.0.1", "Logged in", "/opt/x"]}])

    assert output =~ "(DRIFT)"
  end

  test "an agent the machine never reported says so rather than matching" do
    output = render([])

    assert output =~ "not reported"
    refute output =~ "(matches)"
  end

  test "distinguishes the supported managed Herdr from the removed interactive one" do
    pinned = Map.fetch!(Toolchain.pinned(), "herdr")

    output =
      render([
        {"herdr_installation", "managed",
         ["herdr #{pinned}", "ptc-manager-worker", "managed-session", "/opt/herdr"]},
        {"herdr_installation", "interactive",
         ["absent", "agent", "none", "/home/agent/.local/bin/herdr"]}
      ])

    assert output =~ "Managed (supported)"
    assert output =~ "owner     ptc-manager-worker"
    assert output =~ "session   managed-session"
    assert output =~ "#{pinned} (matches)"
    assert output =~ "Interactive (unsupported)"
    assert output =~ "removed (expected)"
  end

  test "warns when the unsupported interactive Herdr returns" do
    output =
      render([
        {"herdr_installation", "interactive",
         ["present", "agent", "unknown", "/home/agent/.local/bin/herdr"]}
      ])

    assert output =~ "present (REMOVE)"
  end

  # The pair that decides whether the next deployment may move Herdr's link. A
  # restarted Herdr reports every restored pane as idle again, so this reads
  # non-zero far more often than a maintainer expects.
  test "nothing retained means a deployment would move Herdr's link" do
    output = render([{"herdr", "live_agents", ["0"]}, {"herdr", "live_runs", ["0"]}])

    assert output =~ "would move Herdr's link"
  end

  test "one retained agent means a deployment would leave Herdr's link" do
    output = render([{"herdr", "live_agents", ["1"]}, {"herdr", "live_runs", ["0"]}])

    assert output =~ "would leave Herdr's link"
  end

  test "an unreported Herdr count is unknown rather than zero" do
    output = render([])

    assert output =~ "live agents  unknown"
    refute output =~ "would move Herdr's link"
  end

  test "a repository with no variables says none rather than nothing" do
    output = render([{"env", "owner/repository", [""]}])

    assert output =~ "owner/repository  none"
  end

  test "a repository's variable names are listed without their values" do
    output = render([{"env", "owner/repository", ["OPENROUTER_API_KEY,TOKEN"]}])

    assert output =~ "owner/repository  OPENROUTER_API_KEY,TOKEN"
    assert output =~ "values are write-only"
  end

  defp render(records) do
    capture_io(fn -> Agents.render(records) end)
  end
end
