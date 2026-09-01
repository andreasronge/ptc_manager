defmodule PtcManager.Automations.Bootstrap do
  @moduledoc false
  use GenServer

  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    case PtcManager.Automations.ensure_defaults_for_all() do
      :ok -> :ok
      {:error, reason} -> Logger.error("Automation bootstrap failed: #{inspect(reason)}")
    end

    :ignore
  end
end
