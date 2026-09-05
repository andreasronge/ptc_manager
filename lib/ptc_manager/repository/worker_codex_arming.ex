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

  The same file silences the one interactive prompt no argument covers. As it
  approaches a rate limit Codex raises a menu offering a cheaper model, and an
  unattended agent stops there mid-task. Herdr reports that parked pane as
  `done`, so the branch is reconciled while it still holds no commits and the
  job stalls on `:no_commits` with the work uncommitted in its worktree.

  The model the Codex profile names is recorded for the same reason. It is
  passed at `herdr agent start` as well, but a restore that drops the arguments
  would otherwise bring the pane back on the account's default model rather
  than the one the maintainer chose.
  """

  alias PtcManager.AgentProfiles
  alias PtcManager.Repository.WorkerHelper

  @doc "Arms the worker's Codex configuration; other agent kinds need nothing."
  def prepare("codex"), do: arm(AgentProfiles.model("codex"))
  def prepare(_kind), do: :ok

  @doc """
  Records the managed policy, and the model when the Codex profile names one.
  """
  def arm(model \\ nil) do
    if WorkerHelper.worker_boundary?() do
      case run(["arm" | List.wrap(model)]) do
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
