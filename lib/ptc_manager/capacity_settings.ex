defmodule PtcManager.CapacitySettings do
  @moduledoc "Persists and applies the machine-wide light and heavy agent limits."

  use GenServer

  alias PtcManager.Operations.CapacitySetting
  alias PtcManager.Repo

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def current do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, :current),
      else: load_or_create()
  end

  def update(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:update, attrs})

  @impl true
  def init(:ok) do
    setting = load_or_create()
    apply_runtime(setting)
    {:ok, setting}
  end

  @impl true
  def handle_call(:current, _from, setting), do: {:reply, setting, setting}

  def handle_call({:update, attrs}, _from, setting) do
    case setting |> CapacitySetting.changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        apply_runtime(updated)
        wake_dispatchers()
        PtcManager.Operations.notify_changed(__MODULE__)
        {:reply, {:ok, updated}, updated}

      {:error, changeset} ->
        {:reply, {:error, changeset}, setting}
    end
  end

  defp load_or_create do
    Repo.one(CapacitySetting) ||
      %CapacitySetting{}
      |> CapacitySetting.changeset(%{
        light_agent_capacity: Application.get_env(:ptc_manager, :light_agent_capacity, 2),
        heavy_agent_capacity: Application.get_env(:ptc_manager, :heavy_agent_capacity, 1)
      })
      |> Repo.insert!()
  end

  defp apply_runtime(setting) do
    Application.put_env(:ptc_manager, :light_agent_capacity, setting.light_agent_capacity)
    Application.put_env(:ptc_manager, :heavy_agent_capacity, setting.heavy_agent_capacity)
  end

  defp wake_dispatchers do
    PtcManager.MaintainerActions.Poller.wake()
    PtcManager.Herdr.Poller.wake()
    PtcManager.Dispatch.Poller.wake()
  end
end
