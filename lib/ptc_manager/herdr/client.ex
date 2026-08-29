defmodule PtcManager.Herdr.Client do
  @moduledoc "Reads Herdr's JSON agent list without controlling any agent."

  @behaviour PtcManager.Herdr

  alias PtcManager.Herdr.Command

  @impl true
  def list_agents do
    timeout = Application.get_env(:ptc_manager, :herdr_timeout_ms, 15_000)

    case Command.run(["agent", "list"], timeout) do
      {:ok, output} -> decode_agents(output)
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_agents(output) when is_binary(output) do
    with {:ok, decoded} <- Jason.decode(output),
         {:ok, agents} <- extract_agents(decoded) do
      {:ok, agents}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_herdr_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_agents(agents) when is_list(agents), do: {:ok, agents}
  defp extract_agents(%{"agents" => agents}) when is_list(agents), do: {:ok, agents}

  defp extract_agents(%{"result" => %{"agents" => agents}}) when is_list(agents),
    do: {:ok, agents}

  defp extract_agents(%{"result" => agents}) when is_list(agents), do: {:ok, agents}
  defp extract_agents(_decoded), do: {:error, :unexpected_herdr_response}
end
