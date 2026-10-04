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

  @pinned PtcManager.Toolchain.Manifest.parse!(File.read!(@manifest))

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
      deferred: true,
      entry: "herdr"
    },
    %{key: :node, name: "Node", pin: "node", link: "node", prefix: "ptc-manager-node-"},
    %{key: :pnpm, name: "pnpm", pin: "pnpm", link: "pnpm", prefix: "ptc-manager-pnpm-"},
    %{key: :mise, name: "mise", pin: "mise", link: "mise", prefix: "ptc-manager-mise-"},
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

  @preview_programs @programs ++ [%{key: :hex, name: "Hex and Rebar3", pin: "hex"}]

  # The deployment reads more than the programs listed above: a digest for every
  # download it does not take from npm, and the gate's own build tools. A
  # release that compiled without one of them would only fail on the machine,
  # halfway through a deployment, so require the whole set here.
  @required Enum.map(@programs, & &1.pin) ++
              ~w(cursor_agent_sha256 herdr_protocol herdr_sha256 mise_sha256 hex rebar3_sha512)

  @unpinned Enum.reject(@required, &Map.has_key?(@pinned, &1))

  if @unpinned != [] do
    raise "deploy/toolchain-versions pins nothing for: " <> Enum.join(@unpinned, ", ")
  end

  @type status :: :matched | :staged | :drifted | :absent

  @digest_keys %{
    cursor_agent: ["cursor_agent_sha256"],
    herdr: ["herdr_protocol", "herdr_sha256"],
    mise: ["mise_sha256"],
    hex: ["rebar3_sha512"]
  }

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

  @doc "Whether a repository is the one whose toolchain this release deploys."
  def own_repository?(repository) do
    configured =
      Application.get_env(:ptc_manager, :toolchain_repository, "andreasronge/ptc_manager")

    String.downcase(repository.github_owner <> "/" <> repository.github_name) ==
      String.downcase(configured)
  end

  @doc "Every manifest key a deployment reads, which is every key this release requires."
  @spec required_pins() :: [String.t()]
  def required_pins, do: @required

  @doc """
  One entry per pinned program, in the order a maintainer reads them: the agents
  that do the work first, then the toolchain underneath them.
  """
  @spec report() :: [program()]
  def report, do: Enum.map(@programs, &describe/1)

  @doc "Changes a deployment at the next revision would make to the toolchain."
  def preview(contents) when is_binary(contents) do
    try do
      next = PtcManager.Toolchain.Manifest.parse!(contents)
      missing = Enum.reject(@required, &Map.has_key?(next, &1))

      if missing != [] do
        {:error, "missing pins: #{Enum.join(missing, ", ")}"}
      else
        changes =
          @preview_programs
          |> Enum.flat_map(fn program ->
            keys = [program.pin | Map.get(@digest_keys, program.key, [])]

            if Enum.any?(keys, &(Map.fetch!(@pinned, &1) != Map.fetch!(next, &1))) do
              [
                %{
                  key: program.key,
                  name: program.name,
                  current: Map.fetch!(@pinned, program.pin),
                  next: Map.fetch!(next, program.pin),
                  digest_changed?:
                    Enum.any?(tl(keys), &(Map.fetch!(@pinned, &1) != Map.fetch!(next, &1))),
                  protocol: if(program.key == :herdr, do: Map.fetch!(next, "herdr_protocol")),
                  deferred?: Map.get(program, :deferred, false)
                }
              ]
            else
              []
            end
          end)

        {:ok, changes}
      end
    rescue
      error in RuntimeError -> {:error, Exception.message(error)}
    end
  end

  @doc """
  What the report says about the machine as a whole.

  `:absent` means this machine links no deployed program at all, which is every
  development machine. One missing program among installed ones is not that: it
  is a program this release pins that the machine does not have.
  """
  @spec summary([program()]) :: status()
  def summary(report) do
    cond do
      Enum.all?(report, &(&1.status == :absent)) -> :absent
      Enum.any?(report, &(&1.status in [:drifted, :absent])) -> :drifted
      Enum.any?(report, &(&1.status == :staged)) -> :staged
      true -> :matched
    end
  end

  defp describe(program) do
    pinned = Map.fetch!(@pinned, program.pin)
    prefix = install_root() <> "/" <> program.prefix
    link = Path.join(link_dir(), program.link)
    target = canonical_target(link)

    described = %{
      key: program.key,
      name: program.name,
      pinned: pinned,
      linked: linked_version(target, prefix),
      target: target,
      installed?: File.dir?(prefix <> pinned),
      # Only a pinned program that would actually run once linked is waiting on
      # a deployment; anything else at that path is drift no deployment step is
      # pending for.
      staged?: stageable?(program, prefix <> pinned),
      # A link is not a program: File.read_link/1 reads the text a symlink
      # holds without following it, so a link naming the pinned version can
      # still point at nothing, at a directory, or at something nobody can run.
      runnable?: entry_point?(target, program),
      deferred?: Map.get(program, :deferred, false)
    }

    described
    |> Map.put(:status, status(described))
    |> Map.drop([:installed?, :runnable?, :staged?, :deferred?])
  end

  # A name on the PATH that is not a symlink was put there by hand: the
  # deployment only ever links a versioned directory it installed itself. The
  # target is normalized first, so a path that walks back out of a pinned
  # directory cannot be read as the version it starts with.
  defp canonical_target(link) do
    case File.read_link(link) do
      # A relative target resolves against the directory holding the link, not
      # against whatever directory this process happens to be running in.
      {:ok, target} -> Path.expand(target, Path.dirname(link))
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

  # Inspecting the target answers this; running it would hand a program the
  # deployment has not vouched for the console's own process. The name has to
  # match too, because every other executable in a pinned tree sits under the
  # same versioned directory and would otherwise pass for the one that is linked.
  defp entry_point?(nil, _program), do: false

  defp entry_point?(target, program) do
    case File.stat(target) do
      # Agent CLIs are world-executable. Herdr is deliberately executable only
      # by its root owner and ptc-manager-worker group so the interactive login
      # cannot create a second server session with the managed binary.
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        executable_bit = if program.key == :herdr, do: 0o010, else: 0o001
        Bitwise.band(mode, executable_bit) != 0 and Path.basename(target) == program.link

      _unreadable ->
        false
    end
  end

  defp stageable?(%{deferred: true, entry: entry} = program, directory),
    do: entry_point?(Path.join(directory, entry), program)

  defp stageable?(_program, _directory), do: false

  defp status(%{pinned: version, linked: version, runnable?: true}), do: :matched
  defp status(%{staged?: true}), do: :staged
  defp status(%{target: nil, installed?: false}), do: :absent
  defp status(_program), do: :drifted

  defp link_dir, do: Application.get_env(:ptc_manager, :toolchain_link_dir, "/usr/local/bin")

  defp install_root, do: Application.get_env(:ptc_manager, :toolchain_install_root, "/opt")
end
