defmodule PtcManager.Repository.WorkerCodexArming do
  @moduledoc """
  Records the managed Codex policy in the worker's own Codex configuration.

  PtcManager starts Codex with `--dangerously-bypass-approvals-and-sandbox` so
  an unattended agent never stops at an approval prompt. Those arguments belong
  to that one process. When the Herdr server restarts it restores a pane by
  running `codex resume <session-id>` with no arguments, so the agent returns
  asking permission before every command and waits for an answer nobody is
  watching for; the pull request it was retained for then stops moving.

  Codex reads the same approval and sandbox policy from `config.toml`, so
  recording it in the worker's own configuration through a root-owned helper
  keeps a resumed agent exactly as capable as a started one. The account runs
  managed agents only and already receives the arguments on every start, so the
  recorded policy widens nothing that was previously narrower.
  """

  alias PtcManager.Repository.WorkerHelper

  @doc "Arms the worker's Codex configuration; other agent kinds need nothing."
  def prepare("codex"), do: arm()
  def prepare(_kind), do: :ok

  @doc "Records the managed approval and sandbox policy for the worker account."
  def arm do
    if WorkerHelper.worker_boundary?() do
      case run(["arm"]) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:worker_codex_arming_failed, status, bounded(output)}}
      end
    else
      :ok
    end
  end

  defp run(args) do
    command = Application.get_env(:ptc_manager, :worker_codex_arming_command, __MODULE__.Runner)
    command.arming_command(args)
  end

  defp bounded(output), do: WorkerHelper.bounded(output)

  defmodule Runner do
    @moduledoc false

    alias PtcManager.Repository.WorkerHelper

    @helper "/usr/local/bin/ptc-manager-worker-codex-arm"

    def arming_command(args) when is_list(args) do
      WorkerHelper.run(
        Application.get_env(:ptc_manager, :worker_codex_arming_helper, @helper),
        args
      )
    end
  end
end
