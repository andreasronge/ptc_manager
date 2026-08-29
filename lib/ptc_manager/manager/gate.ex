defmodule PtcManager.Manager.Gate do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def checkout, do: GenServer.call(__MODULE__, {:checkout, self()})
  def checkin(lease), do: GenServer.call(__MODULE__, {:checkin, lease})

  @impl true
  def init(:ok) do
    max = Application.get_env(:ptc_manager, :manager_concurrency, 1)
    {:ok, %{max: max, leases: %{}}}
  end

  @impl true
  def handle_call({:checkout, owner}, _from, state) when map_size(state.leases) < state.max do
    lease = make_ref()
    monitor = Process.monitor(owner)
    {:reply, {:ok, lease}, put_in(state.leases[lease], monitor)}
  end

  def handle_call({:checkout, _owner}, _from, state),
    do: {:reply, {:error, :manager_busy}, state}

  def handle_call({:checkin, lease}, _from, state) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        {:reply, :ok, state}

      {monitor, leases} ->
        Process.demonitor(monitor, [:flush])
        {:reply, :ok, %{state | leases: leases}}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    leases = Map.reject(state.leases, fn {_lease, lease_monitor} -> lease_monitor == monitor end)
    {:noreply, %{state | leases: leases}}
  end
end
