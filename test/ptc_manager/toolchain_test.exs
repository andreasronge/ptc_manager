defmodule PtcManager.ToolchainTest do
  # The report reads real link targets, so the roots it reads are application
  # environment this test rewrites.
  use ExUnit.Case, async: false

  alias PtcManager.Toolchain
  alias PtcManager.Toolchain.Manifest

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-toolchain-#{System.unique_integer([:positive, :monotonic])}"
      )

    link_dir = Path.join(root, "bin")
    install_root = Path.join(root, "opt")
    File.mkdir_p!(link_dir)
    File.mkdir_p!(install_root)

    previous_link_dir = Application.get_env(:ptc_manager, :toolchain_link_dir)
    previous_install_root = Application.get_env(:ptc_manager, :toolchain_install_root)
    Application.put_env(:ptc_manager, :toolchain_link_dir, link_dir)
    Application.put_env(:ptc_manager, :toolchain_install_root, install_root)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :toolchain_link_dir, previous_link_dir)
      Application.put_env(:ptc_manager, :toolchain_install_root, previous_install_root)
      File.rm_rf!(root)
    end)

    %{link_dir: link_dir, install_root: install_root}
  end

  test "a machine that links nothing reports every program as absent" do
    report = Toolchain.report()

    assert Enum.all?(report, &(&1.status == :absent))
    assert Enum.all?(report, &is_nil(&1.linked))
    assert Toolchain.summary(report) == :absent
  end

  test "a machine linking exactly what this release pins matches", context do
    install_pinned_programs(context)

    report = Toolchain.report()

    assert Enum.all?(report, &(&1.status == :matched)), inspect(report)
    assert Enum.all?(report, &(&1.linked == &1.pinned))
    assert Toolchain.summary(report) == :matched
  end

  test "a program linked outside the version this release pins is drift", context do
    install_pinned_programs(context)

    # What the machine looked like before the deployment owned the agent CLIs:
    # Codex extracted into /opt by hand, Claude Code installed into the Node tree.
    link(context, "codex", "codex-by-hand/bin/codex")
    link(context, "claude", "ptc-manager-node-#{pinned("node")}/bin/claude")

    report = Toolchain.report()

    assert %{linked: nil, status: :drifted} = program(report, :codex)
    assert %{linked: nil, status: :drifted} = program(report, :claude_code)
    assert %{status: :matched} = program(report, :cursor_agent)
    assert Toolchain.summary(report) == :drifted
  end

  test "an installed program the machine has not linked yet is staged", context do
    install_pinned_programs(context)

    # Herdr's link moves only when the deployment restarts the server, so the
    # pinned build sits installed beside a link that still names the old one.
    File.rm!(Path.join(context.link_dir, "herdr"))
    File.write!(Path.join(context.link_dir, "herdr"), "the previously copied binary")

    report = Toolchain.report()

    assert %{linked: nil, status: :staged, pinned: pinned} = program(report, :herdr)
    assert pinned == pinned("herdr")
    assert Toolchain.summary(report) == :staged
  end

  test "a program linked at another pinned-looking version reports that version", context do
    install_pinned_programs(context)
    link(context, "cursor-agent", "ptc-manager-cursor-agent-2020.01.01-abcdef/cursor-agent")

    assert %{linked: "2020.01.01-abcdef", status: :drifted} =
             Toolchain.report() |> program(:cursor_agent)
  end

  # Only Herdr's link is allowed to lag its installation. Reporting a missing
  # Codex link as awaiting a deployment would point a maintainer at a step that
  # repairs nothing here.
  test "an installed program that is not deferred and is not linked is drift", context do
    install_pinned_programs(context)
    File.rm!(Path.join(context.link_dir, "codex"))

    report = Toolchain.report()

    assert %{linked: nil, target: nil, status: :drifted} = program(report, :codex)
    assert %{status: :matched} = program(report, :herdr)
    assert Toolchain.summary(report) == :drifted
  end

  # A symlink holds text, not a program. One naming the pinned version while
  # pointing at nothing means the command does not run at all, which is the one
  # thing a report claiming "pinned version" must never say.
  test "a link naming the pinned version but pointing at nothing is not a match", context do
    install_pinned_programs(context)
    File.rm!(Path.join(context.install_root, "ptc-manager-pnpm-#{pinned("pnpm")}/pnpm"))

    report = Toolchain.report()

    assert %{linked: linked, status: :drifted} = program(report, :pnpm)
    assert linked == pinned("pnpm")
    assert %{status: :matched} = program(report, :node)
  end

  # The console reads the machine rather than running it, so what it finds at
  # the end of a link has to look like a program before it says one is there.
  test "a link to something that is not an executable file is not a match", context do
    install_pinned_programs(context)

    codex = Path.join(context.install_root, "ptc-manager-codex-#{pinned("codex")}")
    File.chmod!(Path.join(codex, "lib/node_modules/@openai/codex/bin/codex"), 0o644)

    herdr = Path.join(context.install_root, "ptc-manager-herdr-#{pinned("herdr")}/herdr")
    File.rm!(herdr)
    File.mkdir_p!(herdr)

    report = Toolchain.report()

    assert %{status: :drifted} = program(report, :codex)

    # A pinned Herdr that would not run once linked is not waiting on a
    # deployment either: no deployment step repairs it.
    assert %{status: :drifted} = program(report, :herdr)
  end

  # Every other executable in a pinned tree sits under the same versioned
  # directory, so the version in a link target does not say which program the
  # link actually reaches.
  test "a link to another executable inside the pinned tree is not a match", context do
    install_pinned_programs(context)

    node_tree = Path.join(context.install_root, "ptc-manager-node-#{pinned("node")}")
    npm = Path.join(node_tree, "bin/npm")
    File.write!(npm, "another program in the pinned tree")
    File.chmod!(npm, 0o755)
    link(context, "node", "ptc-manager-node-#{pinned("node")}/bin/npm")

    assert %{linked: linked, status: :drifted} = Toolchain.report() |> program(:node)
    assert linked == pinned("node")
  end

  # The deployment installs every program root-owned and world-executable, so a
  # mode only root can run means the worker's agents cannot start it.
  test "a target only root can execute is not a match", context do
    install_pinned_programs(context)

    File.chmod!(
      Path.join(
        context.install_root,
        "ptc-manager-cursor-agent-#{pinned("cursor_agent")}/cursor-agent"
      ),
      0o700
    )

    assert %{status: :drifted} = Toolchain.report() |> program(:cursor_agent)
  end

  # A path that starts inside a pinned directory and walks back out of it is not
  # that directory's program.
  test "a link that leaves the pinned directory is not a match", context do
    install_pinned_programs(context)

    unmanaged = Path.join(context.install_root, "unmanaged/bin")
    File.mkdir_p!(unmanaged)
    File.write!(Path.join(unmanaged, "node"), "a program from somewhere else")
    File.chmod!(Path.join(unmanaged, "node"), 0o755)
    link(context, "node", "ptc-manager-node-#{pinned("node")}/../unmanaged/bin/node")

    assert %{status: :drifted} = Toolchain.report() |> program(:node)
  end

  # A machine with one program missing is not a machine that matches: no
  # restart or deployment step is pending, the program simply is not there.
  test "one missing program among installed ones is drift", context do
    install_pinned_programs(context)
    File.rm!(Path.join(context.link_dir, "pnpm"))
    File.rm_rf!(Path.join(context.install_root, "ptc-manager-pnpm-#{pinned("pnpm")}"))

    report = Toolchain.report()

    assert %{status: :absent} = program(report, :pnpm)
    assert Toolchain.summary(report) == :drifted
  end

  # A release that compiled without a digest the deployment reads would only
  # fail on the machine, halfway through a deployment.
  test "the release requires every pin a deployment reads" do
    pinned = Toolchain.pinned()

    for key <- Toolchain.required_pins() do
      assert Map.has_key?(pinned, key), key
    end

    for key <- ~w(cursor_agent_sha256 herdr_sha256 mise_sha256 hex rebar3_sha512) do
      assert key in Toolchain.required_pins(), key
    end
  end

  # Unix resolves a relative link against the directory holding the link, not
  # against whatever directory the console happens to be running in.
  test "a relative link resolves against the directory holding it", context do
    install_pinned_programs(context)
    File.rm!(Path.join(context.link_dir, "pnpm"))

    File.ln_s!(
      "../opt/ptc-manager-pnpm-#{pinned("pnpm")}/pnpm",
      Path.join(context.link_dir, "pnpm")
    )

    assert %{linked: linked, status: :matched} = Toolchain.report() |> program(:pnpm)
    assert linked == pinned("pnpm")
  end

  test "the manifest pins every digest the deployment verifies a download against" do
    pinned = Toolchain.pinned()

    for key <- ~w(herdr_sha256 mise_sha256 cursor_agent_sha256) do
      assert String.match?(Map.fetch!(pinned, key), ~r/^[0-9a-f]{64}$/), key
    end

    assert String.match?(Map.fetch!(pinned, "rebar3_sha512"), ~r/^[0-9a-f]{128}$/)
  end

  # The deployment's reader stops on a line it cannot read, so a release that
  # compiled against a manifest the deployment would reject could install a
  # version the console never reports.
  test "the manifest parser refuses what the deployment's reader refuses" do
    assert %{"codex" => "0.1.0", "herdr" => "0.8.2"} =
             Manifest.parse!("# a comment\n\ncodex=0.1.0\nherdr=0.8.2\n")

    assert_raise RuntimeError, ~r/pins codex more than once/, fn ->
      Manifest.parse!("codex=0.1.0\ncodex=0.2.0\n")
    end

    # The case a filtering parser accepts: a duplicate whose value is empty.
    assert_raise RuntimeError, ~r/line 2 is not a pinned version: codex=/, fn ->
      Manifest.parse!("codex=0.1.0\ncodex=\n")
    end

    assert_raise RuntimeError, ~r/line 1 is not a pinned version/, fn ->
      Manifest.parse!("codex = 0.1.0\n")
    end

    assert_raise RuntimeError, ~r/line 1 is not a pinned version/, fn ->
      Manifest.parse!("codex=$(id -u)\n")
    end

    # The deployment's reader counts only spaces and tabs as blank, so a line of
    # other whitespace must not compile a release the deployment would refuse.
    assert %{"codex" => "0.1.0"} = Manifest.parse!(" \t\ncodex=0.1.0\n")

    assert_raise RuntimeError, ~r/line 1 is not a pinned version/, fn ->
      Manifest.parse!("\u00a0\ncodex=0.1.0\n")
    end
  end

  defp install_pinned_programs(context) do
    Enum.each(
      [
        {"codex", "ptc-manager-codex-", "codex", "/lib/node_modules/@openai/codex/bin/codex"},
        {"claude_code", "ptc-manager-claude-code-", "claude", "/bin/claude"},
        {"cursor_agent", "ptc-manager-cursor-agent-", "cursor-agent", "/cursor-agent"},
        {"herdr", "ptc-manager-herdr-", "herdr", "/herdr"},
        {"node", "ptc-manager-node-", "node", "/bin/node"},
        {"pnpm", "ptc-manager-pnpm-", "pnpm", "/pnpm"},
        {"mise", "ptc-manager-mise-", "mise", "/mise"},
        {"erlang", "ptc-manager-gate-mise/data/installs/erlang/", "erl", "/bin/erl"},
        {"elixir", "ptc-manager-gate-mise/data/installs/elixir/", "elixir", "/bin/elixir"}
      ],
      fn {key, prefix, link_name, entry_point} ->
        directory = prefix <> pinned(key)
        entry = Path.join(context.install_root, directory <> entry_point)
        File.mkdir_p!(Path.dirname(entry))
        File.write!(entry, "the installed program")
        File.chmod!(entry, 0o755)
        link(context, link_name, directory <> entry_point)
      end
    )
  end

  defp link(context, link_name, relative_target) do
    link_path = Path.join(context.link_dir, link_name)
    File.rm(link_path)
    File.ln_s!(Path.join(context.install_root, relative_target), link_path)
  end

  defp pinned(key), do: Map.fetch!(Toolchain.pinned(), key)

  defp program(report, key), do: Enum.find(report, &(&1.key == key))
end
