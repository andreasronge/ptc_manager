defmodule PtcManager.Repository.WorkerHelper do
  @moduledoc """
  Runs a helper as the configured Herdr worker, or as the local service account.

  An agent's persistent configuration lives in the worker's own home directory,
  which only the worker may write. On a separate-account host, PtcManager reaches those files
  through a narrowly scoped sudo rule, so every helper shares this invocation
  and the same worker boundary check.
  """

  alias PtcManager.{CommandEnvironment, Host}

  @doc "Runs the helper as the worker and returns its combined output and status."
  def run(helper, args) when is_binary(helper) and is_list(args) do
    {binary, arguments} = Host.agent_command(helper, args)

    System.cmd(binary, arguments,
      env: CommandEnvironment.scrub(),
      stderr_to_stdout: true
    )
  rescue
    error -> {inspect(error.__struct__), 127}
  end

  @doc "Trims helper output to its last kilobyte for an error tuple."
  def bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)
end
