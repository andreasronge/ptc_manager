defmodule PtcManager.MaintainerActions.HerdrOutput do
  @moduledoc false

  def settled_state(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> find_state(decoded)
      _error -> if String.contains?(String.downcase(output), "blocked"), do: "blocked"
    end
  end

  defp find_state(%{} = value) do
    Enum.find_value(["agent_status", "status", "state"], &Map.get(value, &1)) ||
      Enum.find_value(value, fn {_key, nested} -> find_state(nested) end)
  end

  defp find_state([head | tail]), do: find_state(head) || find_state(tail)
  defp find_state([]), do: nil
  defp find_state(_value), do: nil
end
