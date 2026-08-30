defmodule PtcManager.Herdr.Transcript do
  @moduledoc "Reads a bounded, display-only snapshot of a known Herdr agent terminal."

  alias PtcManager.Herdr.Command
  alias PtcManager.Operations.AgentRun

  @line_limit 120
  @character_limit 40_000
  @timeout 10_000

  def read(run, command \\ Command)

  def read(%AgentRun{agent_name: name}, command)
      when is_binary(name) and name != "" do
    case command.run(["agent", "read", name, "--lines", Integer.to_string(@line_limit)], @timeout) do
      {:ok, output} ->
        {:ok, sanitize(output)}

      {:error, :herdr_timeout} ->
        {:error, "The terminal snapshot timed out. Try opening it again."}

      {:error, _reason} ->
        {:error, "This agent terminal is no longer available."}
    end
  end

  def read(%AgentRun{}, _command), do: {:error, "This run has no Herdr agent name."}

  defp sanitize(output) do
    output
    |> String.replace_invalid("�")
    |> then(&Regex.replace(~r/\x1B\][^\x07]*(?:\x07|\x1B\\)/, &1, ""))
    |> then(&Regex.replace(~r/\x1B\[[0-?]*[ -\/]*[@-~]/, &1, ""))
    |> String.trim()
    |> keep_tail(@character_limit)
  end

  defp keep_tail(value, limit) when byte_size(value) <= limit, do: value

  defp keep_tail(value, limit),
    do: "… earlier terminal output omitted …\n" <> String.slice(value, -limit, limit)
end
