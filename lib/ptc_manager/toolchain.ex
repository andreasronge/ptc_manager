defmodule PtcManager.Toolchain do
  @moduledoc """
  Reports the third-party programs a release pins against the ones the machine
  links.

  `deploy/toolchain-versions` is the only place a version of anything third
  party is written. The deployment installs exactly what it names into a
  root-owned `/opt/ptc-manager-<program>-<version>` directory, checks the
  version it actually got, and links the entry point into `/usr/local/bin`. The
  linked path therefore names the running version, and this module reads it
  without executing anything an agent could have replaced.

  A program can be pinned, installed, and still not linked: Herdr's link moves
  only when the deployment restarts `ptc_manager-herdr`, because a client whose
  protocol does not match the running server breaks the coordinator's view of
  every agent. That program reports as staged until the restart happens.
  """

  @manifest Path.expand("../../deploy/toolchain-versions", __DIR__)
  @external_resource @manifest

  @entry ~r/^([a-z0-9_]+)=([A-Za-z0-9][A-Za-z0-9._-]*)$/

  @pinned @manifest
          |> File.read!()
          |> String.split("\n")
          |> Enum.flat_map(fn line ->
            case Regex.run(@entry, line, capture: :all_but_first) do
              [key, value] -> [{key, value}]
              nil -> []
            end
          end)
          |> Map.new()

  # `link` is the name on the worker's service PATH; `prefix` is what the
  # deployment puts in front of the version when it installs the program, so the
  # segment following it in a link target is the version that runs. Herdr is
  # `deferred`: its link waits for the next `ptc_manager-herdr` restart, so an
  # installed version it does not yet link is staged rather than drift.
  @programs [
    %{key: :codex, name: "Codex CLI", pin: "codex", link: "codex", prefix: "ptc-manager-codex-"},
    %{
      key: :claude_code,
      name: "Claude Code",
      pin: "claude_code",
      link: "claude",
      prefix: "ptc-manager-claude-code-"
    },
    %{
      key: :cursor_agent,
      name: "Cursor CLI",
      pin: "cursor_agent",
      link: "cursor-agent",
      prefix: "ptc-manager-cursor-agent-"
    },
    %{
      key: :herdr,
      name: "Herdr",
      pin: "herdr",
      link: "herdr",
      prefix: "ptc-manager-herdr-",
      deferred: true
    },
    %{key: :node, name: "Node", pin: "node", link: "node", prefix: "ptc-manager-node-"},
    %{key: :pnpm, name: "pnpm", pin: "pnpm", link: "pnpm", prefix: "ptc-manager-pnpm-"},
    %{
      key: :erlang,
      name: "Erlang/OTP",
      pin: "erlang",
      link: "erl",
      prefix: "ptc-manager-gate-mise/data/installs/erlang/"
    },
    %{
      key: :elixir,
      name: "Elixir",
      pin: "elixir",
      link: "elixir",
      prefix: "ptc-manager-gate-mise/data/installs/elixir/"
    }
  ]

  @unpinned Enum.reject(@programs, &Map.has_key?(@pinned, &1.pin))

  if @unpinned != [] do
    raise "deploy/toolchain-versions pins no version for: " <>
            Enum.map_join(@unpinned, ", ", & &1.pin)
  end

  @type status :: :matched | :staged | :drifted | :absent

  @type program :: %{
          key: atom(),
          name: String.t(),
          pinned: String.t(),
          linked: String.t() | nil,
          target: String.t() | nil,
          status: status()
        }

  @doc "The versions this release pins, keyed by manifest key."
  @spec pinned() :: %{String.t() => String.t()}
  def pinned, do: @pinned

  @doc """
  One entry per pinned program, in the order a maintainer reads them: the agents
  that do the work first, then the toolchain underneath them.
  """
  @spec report() :: [program()]
  def report, do: Enum.map(@programs, &describe/1)

  @doc """
  What the report says about the machine as a whole.

  `:absent` means this machine links no deployed program at all, which is every
  development machine.
  """
  @spec summary([program()]) :: status() | :absent
  def summary(report) do
    cond do
      Enum.all?(report, &(&1.status == :absent)) -> :absent
      Enum.any?(report, &(&1.status == :drifted)) -> :drifted
      Enum.any?(report, &(&1.status == :staged)) -> :staged
      true -> :matched
    end
  end

  defp describe(program) do
    pinned = Map.fetch!(@pinned, program.pin)
    prefix = install_root() <> "/" <> program.prefix
    target = link_target(Path.join(link_dir(), program.link))

    described = %{
      key: program.key,
      name: program.name,
      pinned: pinned,
      linked: linked_version(target, prefix),
      target: target,
      installed?: File.dir?(prefix <> pinned),
      deferred?: Map.get(program, :deferred, false)
    }

    described |> Map.put(:status, status(described)) |> Map.drop([:installed?, :deferred?])
  end

  # A name on the PATH that is not a symlink was put there by hand: the
  # deployment only ever links a versioned directory it installed itself.
  defp link_target(link) do
    case File.read_link(link) do
      {:ok, target} -> target
      {:error, :enoent} -> nil
      {:error, _not_a_link} -> link
    end
  end

  defp linked_version(nil, _prefix), do: nil

  defp linked_version(target, prefix) do
    with true <- String.starts_with?(target, prefix),
         [version | _rest] <- target |> String.replace_prefix(prefix, "") |> String.split("/"),
         true <- version != "" do
      version
    else
      _unmanaged -> nil
    end
  end

  defp status(%{pinned: version, linked: version}), do: :matched
  defp status(%{target: nil, installed?: true}), do: :staged
  defp status(%{target: nil}), do: :absent
  defp status(%{deferred?: true, installed?: true}), do: :staged
  defp status(_program), do: :drifted

  defp link_dir, do: Application.get_env(:ptc_manager, :toolchain_link_dir, "/usr/local/bin")

  defp install_root, do: Application.get_env(:ptc_manager, :toolchain_install_root, "/opt")
end
