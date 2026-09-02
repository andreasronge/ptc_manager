defmodule PtcManager.DeploymentCoordinator do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def wake do
    if enabled?() and Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :wake)
    :ok
  end

  @impl true
  def init(:ok) do
    if enabled?(), do: send(self(), :advance)
    {:ok, %{timer_ref: nil}}
  end

  @impl true
  def handle_info(:advance, state) do
    _ = PtcManager.Deployments.advance()
    {:noreply, schedule(%{state | timer_ref: nil})}
  end

  @impl true
  def handle_cast(:wake, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)
    send(self(), :advance)
    {:noreply, %{state | timer_ref: nil}}
  end

  defp schedule(state) do
    if enabled?() do
      interval = Application.get_env(:ptc_manager, :deployment_poll_interval_ms, 2_000)
      %{state | timer_ref: Process.send_after(self(), :advance, max(interval, 250))}
    else
      %{state | timer_ref: nil}
    end
  end

  defp enabled?, do: Application.get_env(:ptc_manager, :deployment_poll_interval_ms, 0) > 0
end
