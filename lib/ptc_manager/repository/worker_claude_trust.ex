defmodule PtcManager.Repository.WorkerClaudeTrust do
  @moduledoc """
  Pre-answers Claude Code's workspace trust question for one managed directory.

  Claude Code asks "Do you trust this folder?" the first time it starts in a
  directory, records the answer only per exact path in the worker's
  `~/.claude.json`, and offers no start-up flag for an interactive pane. A
  trusted parent directory does not cover its children. Before Herdr starts a
  Claude agent, the coordinator therefore records the answer through a
  root-owned helper running as the worker, and removes it again when a
  disposable workspace is closed.
  """

  alias PtcManager.CommandEnvironment

  @doc "Trusts the workspace when the agent kind needs it; other kinds need nothing."
  def prepare("claude", path) when is_binary(path) do
    case allow(path) do
      {:ok, _outcome} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def prepare(_kind, _path), do: :ok

  def allow(path) when is_binary(path), do: change("allow", path, :worker_claude_trust_failed)

  def revoke(path) when is_binary(path) do
    case change("revoke", path, :worker_claude_untrust_failed) do
      {:ok, _outcome} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp change(mode, path, error) do
    if worker_boundary?() and managed_path?(path) do
      case run([mode, Path.expand(path)]) do
        {_output, 0} -> {:ok, :trusted}
        {output, status} -> {:error, {error, status, bounded(output)}}
      end
    else
      {:ok, :not_required}
    end
  end

  @doc false
  def managed_path?(path) when is_binary(path) do
    expanded = Path.expand(path)

    [:planning_snapshot_root, :worktree_root]
    |> Enum.map(&Application.get_env(:ptc_manager, &1))
    |> Enum.any?(fn
      root when is_binary(root) and root != "" -> Path.dirname(expanded) == Path.expand(root)
      _root -> false
    end)
  end

  defp worker_boundary?,
    do: Application.get_env(:ptc_manager, :herdr_run_as_user) not in [nil, ""]

  defp run(args) do
    command = Application.get_env(:ptc_manager, :worker_claude_trust_command, __MODULE__.Runner)
    command.trust_command(args)
  end

  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)

  defmodule Runner do
    @moduledoc false

    @helper "/usr/local/bin/ptc-manager-worker-claude-trust"

    def trust_command(args) when is_list(args) do
      user = Application.fetch_env!(:ptc_manager, :herdr_run_as_user)
      helper = Application.get_env(:ptc_manager, :worker_claude_trust_helper, @helper)

      System.cmd("/usr/bin/sudo", ["-n", "-H", "-u", user, "--", helper | args],
        env: CommandEnvironment.scrub(),
        stderr_to_stdout: true
      )
    rescue
      error -> {inspect(error.__struct__), 127}
    end
  end
end
