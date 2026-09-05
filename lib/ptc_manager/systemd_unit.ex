defmodule PtcManager.SystemdUnit do
  @moduledoc """
  Starts one host unit through the coordinator's narrowly scoped sudo rule.

  PtcManager runs with `ProtectSystem=strict`, so work that has to touch the
  host outside its own mount namespace happens in a separate oneshot unit. The
  coordinator may only start those units, never define or reconfigure them, so
  each caller supplies the exact command its rule permits.
  """

  alias PtcManager.CommandEnvironment

  @doc """
  Runs the configured start command, or says it is not configured.

  `:not_configured` is a distinct answer from a failure: a host without the unit
  installed has nothing to report as broken.
  """
  def start(command, args, error_tag)
      when is_binary(command) and command != "" and is_list(args) do
    case System.cmd(command, args, env: CommandEnvironment.scrub(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {error_tag, status, bounded(output)}}
    end
  rescue
    error -> {:error, {error_tag, error.__struct__}}
  end

  def start(_command, _args, _error_tag), do: :not_configured

  defp bounded(value), do: value |> to_string() |> String.slice(0, 2_000)
end
