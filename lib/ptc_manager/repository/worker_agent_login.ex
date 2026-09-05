defmodule PtcManager.Repository.WorkerAgentLogin do
  @moduledoc """
  Refuses to start an agent kind whose worker identity is signed out.

  A signed-out CLI does not fail. It starts, prints its login prompt, and waits
  for a person who is not watching, until the run times out with nothing to show
  for it. Its linked binary and reported version are correct throughout, so
  nothing the Deployments page inspects can see it; only asking the CLI can.

  The check runs where the workspace trust and the Codex policy already run,
  immediately before a pane starts, so both an implementation job and a
  maintainer action refuse the same way and say the same thing. The wrapper
  answers in its exit status; its output is forwarded for a person to read and
  is never parsed.
  """

  alias PtcManager.Repository.WorkerHelper

  @signed_out 3

  @doc """
  Verifies the worker identity one agent kind runs as.

  A kind the wrapper does not know, and any machine that is not the worker
  boundary, need nothing: a development machine starts no managed pane, and a
  kind with no login of its own cannot be signed out of one.
  """
  @spec verify(binary()) :: :ok | {:error, term()}
  def verify(kind) when kind in ~w(codex claude cursor) do
    if WorkerHelper.worker_boundary?() do
      case run([kind]) do
        {_output, 0} ->
          :ok

        {_output, @signed_out} ->
          {:error, {:agent_signed_out, kind}}

        {output, status} ->
          {:error, {:worker_agent_login_failed, kind, status, WorkerHelper.bounded(output)}}
      end
    else
      :ok
    end
  end

  def verify(_kind), do: :ok

  defp run(args) do
    command = Application.get_env(:ptc_manager, :worker_agent_login_command, __MODULE__.Runner)
    command.login_command(args)
  end

  defmodule Runner do
    @moduledoc false

    alias PtcManager.Repository.WorkerHelper

    @helper "/usr/local/bin/ptc-manager-worker-agent-login"

    def login_command(args) when is_list(args) do
      WorkerHelper.run(
        Application.get_env(:ptc_manager, :worker_agent_login_helper, @helper),
        args
      )
    end
  end
end
