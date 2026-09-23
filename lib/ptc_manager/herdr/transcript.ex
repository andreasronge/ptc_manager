defmodule PtcManager.Herdr.Transcript do
  @moduledoc "Reads a bounded, display-only snapshot of a known Herdr agent terminal."

  alias PtcManager.Herdr.Command
  alias PtcManager.Operations.AgentRun

  @line_limit 120
  @character_limit 40_000
  @timeout 10_000

  def read(run, command \\ Command)

  # Unmanaged agents have a kind such as "claude" in agent_name, not a unique
  # Herdr name. A live pane identifies them without guessing between sessions.
  def read(%AgentRun{job_id: nil, agent_action_id: nil, herdr_pane: pane, ended_at: nil}, command)
      when is_binary(pane) and pane != "" do
    read_target(pane, command)
  end

  def read(%AgentRun{job_id: nil, agent_action_id: nil, herdr_pane: pane}, _command)
      when is_binary(pane) and pane != "" do
    {:error, "This agent terminal is no longer available."}
  end

  def read(%AgentRun{agent_name: name}, command)
      when is_binary(name) and name != "" do
    read_target(name, command)
  end

  def read(%AgentRun{}, _command), do: {:error, "This run has no Herdr agent name."}

  defp read_target(target, command) do
    case command.run(
           ["agent", "read", target, "--lines", Integer.to_string(@line_limit)],
           @timeout
         ) do
      {:ok, output} ->
        {:ok, sanitize(output)}

      {:error, :herdr_timeout} ->
        {:error, "The terminal snapshot timed out. Try opening it again."}

      {:error, _reason} ->
        {:error, "This agent terminal is no longer available."}
    end
  end

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
