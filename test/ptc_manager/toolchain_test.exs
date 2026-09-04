defmodule PtcManager.ToolchainTest do
  # The report reads real link targets, so the roots it reads are application
  # environment this test rewrites.
  use ExUnit.Case, async: false

  alias PtcManager.Toolchain

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

  test "the manifest pins a herdr digest the deployment can verify a download against" do
    assert %{"herdr_sha256" => digest} = Toolchain.pinned()
    assert String.match?(digest, ~r/^[0-9a-f]{64}$/)
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
        {"erlang", "ptc-manager-gate-mise/data/installs/erlang/", "erl", "/bin/erl"},
        {"elixir", "ptc-manager-gate-mise/data/installs/elixir/", "elixir", "/bin/elixir"}
      ],
      fn {key, prefix, link_name, entry_point} ->
        directory = prefix <> pinned(key)
        File.mkdir_p!(Path.join(context.install_root, directory))
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
