defmodule PtcManager.Herdr.Client do
  @moduledoc "Reads Herdr's JSON agent list without controlling any agent."

  @behaviour PtcManager.Herdr

  alias PtcManager.Herdr.Command

  @impl true
  def list_agents do
    timeout = Application.get_env(:ptc_manager, :herdr_timeout_ms, 15_000)

    case Command.run(["agent", "list"], timeout) do
      {:ok, output} -> decode_snapshot(output)
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_agents(output) when is_binary(output) do
    with {:ok, snapshot} <- decode_snapshot(output) do
      case snapshot do
        agents when is_list(agents) -> {:ok, agents}
        %{agents: agents} -> {:ok, agents}
      end
    end
  end

  def decode_snapshot(output) when is_binary(output) do
    with {:ok, decoded} <- Jason.decode(output),
         {:ok, snapshot} <- extract_snapshot(decoded) do
      {:ok, snapshot}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_herdr_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_snapshot(agents) when is_list(agents), do: {:ok, agents}

  defp extract_snapshot(%{"agents" => agents} = snapshot) when is_list(agents),
    do: {:ok, snapshot_envelope(snapshot, agents)}

  defp extract_snapshot(%{"result" => %{"agents" => agents} = snapshot}) when is_list(agents),
    do: {:ok, snapshot_envelope(snapshot, agents)}

  defp extract_snapshot(%{"result" => agents}) when is_list(agents), do: {:ok, agents}
  defp extract_snapshot(_decoded), do: {:error, :unexpected_herdr_response}

  defp snapshot_envelope(snapshot, agents) do
    keys = ~w(worker_incarnation_id herdr_incarnation_id snapshot_sequence restart_reason)

    identity =
      keys
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.fetch(snapshot, key) do
          {:ok, value} -> Map.put(acc, String.to_existing_atom(key), value)
          :error -> acc
        end
      end)

    if map_size(identity) == 0, do: agents, else: Map.put(identity, :agents, agents)
  end
end
