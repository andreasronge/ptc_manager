defmodule PtcManager.CommandRunner do
  @moduledoc "Injectable boundary for bounded operating-system commands."

  alias PtcManager.Gateway

  @type result ::
          {:ok, binary()}
          | {:error, {:exit, non_neg_integer(), binary()}}
          | {:error, :timeout}
          | {:error, {:command_failed, term()}}
          | {:error, {:uncertain, term()}}
          | {:error, term()}

  @callback run(binary(), [binary()], keyword()) :: result()

  def run(runner, command, args, options \\ [])
      when is_binary(command) and is_list(args) and is_list(options) do
    Gateway.call(runner, :run, [command, args, options])
  end
end
