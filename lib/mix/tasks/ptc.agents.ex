defmodule Mix.Tasks.Ptc.Agents do
  use Mix.Task

  @shortdoc "Reports the agent CLIs the Herdr machine runs, and their login state"

  @moduledoc """
  Asks the Herdr machine what its agent CLIs actually are and prints the answer.

      mix ptc.agents
      mix ptc.agents --target another-host

  The Deployments page reads link targets and never runs the programs it reports
  on. This task runs them, as `ptc-manager-worker`, because a linked binary that
  matches the manifest can still be signed out, and a signed-out agent stalls on
  its login prompt rather than failing.

  It distinguishes the deployment-managed worker Herdr from the unsupported
  agent-owned interactive path, prints the pair that decides whether the next
  deployment may move Herdr's link, and lists the repository variables an
  implementation agent is given.
  Nothing it does changes the machine, so it needs no deployment of its own.
  """

  alias PtcManager.Toolchain

  @agents [
    {"codex", "Codex CLI", "codex"},
    {"claude_code", "Claude Code", "claude_code"},
    {"cursor_agent", "Cursor CLI", "cursor_agent"}
  ]

  @impl Mix.Task
  def run(args) do
    project_root = Mix.Project.project_file() |> Path.dirname()
    script = Path.join(project_root, "deploy/agent-report")

    unless File.regular?(script) do
      Mix.raise("agent report script not found: #{script}")
    end

    {output, status} = System.cmd(script, args, cd: project_root, stderr_to_stdout: true)

    if status != 0 do
      Mix.raise("Agent report failed with exit status #{status}:\n#{output}")
    end

    output |> parse() |> render()
  end

  @doc false
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t") do
        [kind, key | rest] -> [{kind, key, rest}]
        _other -> []
      end
    end)
  end

  @doc false
  def render(records) do
    render_agents(records)
    render_herdr(records)
    render_environment(records)
  end

  defp render_agents(records) do
    Mix.shell().info("Agent CLIs")

    for {key, name, pin} <- @agents do
      pinned = Map.fetch!(Toolchain.pinned(), pin)

      case find(records, "agent", key) do
        [reported, login, target | _rest] ->
          Mix.shell().info("  #{name}")
          Mix.shell().info("    pinned    #{pinned} #{verdict(reported, pinned)}")
          Mix.shell().info("    reports   #{reported}")
          Mix.shell().info("    login     #{login}")
          Mix.shell().info("    link      #{target}")

        _missing ->
          Mix.shell().info("  #{name}\n    pinned    #{pinned}\n    reports   not reported")
      end
    end
  end

  # The pinned version is a substring test rather than an equality one because
  # each CLI decorates it differently: "codex-cli 0.153.2", "2.1.260 (Claude
  # Code)", and a bare version from Cursor. Normalising three formats here would
  # break on the next one that changes; the version has to appear, and the whole
  # line is printed beside this so a surprising match stays visible.
  defp verdict(reported, pinned) do
    if String.contains?(reported, pinned), do: "(matches)", else: "(DRIFT)"
  end

  defp render_herdr(records) do
    agents = single(records, "herdr", "live_agents")
    runs = single(records, "herdr", "live_runs")
    pinned = Map.fetch!(Toolchain.pinned(), "herdr")

    Mix.shell().info("\nHerdr installations")

    case find(records, "herdr_installation", "managed") do
      [reported, owner, session, target | _rest] ->
        Mix.shell().info("  Managed (supported)")
        Mix.shell().info("    pinned    #{pinned} #{verdict(reported, pinned)}")
        Mix.shell().info("    reports   #{reported}")
        Mix.shell().info("    owner     #{owner}")
        Mix.shell().info("    session   #{session}")
        Mix.shell().info("    link      #{target}")

      _missing ->
        Mix.shell().info("  Managed (supported)\n    reports   not reported")
    end

    case find(records, "herdr_installation", "interactive") do
      ["absent", owner, "none", path | _rest] ->
        Mix.shell().info("  Interactive (unsupported)\n    state     removed (expected)")
        Mix.shell().info("    owner     #{owner}")
        Mix.shell().info("    path      #{path}")

      [state, owner, session, path | _rest] ->
        Mix.shell().info("  Interactive (unsupported)\n    state     #{state} (REMOVE)")
        Mix.shell().info("    owner     #{owner}")
        Mix.shell().info("    session   #{session}")
        Mix.shell().info("    path      #{path}")

      _missing ->
        Mix.shell().info("  Interactive (unsupported)\n    state     not reported")
    end

    Mix.shell().info("\nManaged Herdr activity")
    Mix.shell().info("  live agents  #{agents}")
    Mix.shell().info("  live runs    #{runs}")

    if agents == "0" and runs == "0" do
      Mix.shell().info("  a deployment would move Herdr's link and restart it")
    else
      Mix.shell().info("  a deployment would leave Herdr's link where it is")
    end
  end

  defp render_environment(records) do
    Mix.shell().info("\nRepository variables given to an implementation agent")

    records
    |> Enum.filter(fn {kind, _key, _rest} -> kind == "env" end)
    |> case do
      [] ->
        Mix.shell().info("  no enabled repository")

      entries ->
        for {_kind, repository, rest} <- entries do
          Mix.shell().info("  #{repository}  #{names(rest)}")
        end

        Mix.shell().info("  names only; values are write-only to the console")
        Mix.shell().info("  a maintainer action is given none of these, only a job is")
    end
  end

  defp names([""]), do: "none"
  defp names([names | _rest]) when names != "", do: names
  defp names(_rest), do: "none"

  defp find(records, kind, key) do
    Enum.find_value(records, fn
      {^kind, ^key, rest} -> rest
      _other -> nil
    end)
  end

  defp single(records, kind, key) do
    case find(records, kind, key) do
      [value | _rest] -> value
      _missing -> "unknown"
    end
  end
end
