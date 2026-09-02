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
    {:ok, %{timer_ref: nil, head_checked_at: nil}}
  end

  @impl true
  def handle_info(:advance, state) do
    # A waiting deployment is pinned to the revision it was requested for.
    # Checking the default-branch head once a minute lets it fail with a clear
    # message when the branch moves on, instead of at launch after a long drain.
    check_head? = head_check_due?(state)
    _ = PtcManager.Deployments.advance(check_head?: check_head?)

    state =
      if check_head?,
        do: %{state | head_checked_at: System.monotonic_time(:millisecond)},
        else: state

    {:noreply, schedule(%{state | timer_ref: nil})}
  end

  @impl true
  def handle_cast(:wake, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)
    send(self(), :advance)
    {:noreply, %{state | timer_ref: nil}}
  end

  defp head_check_due?(%{head_checked_at: nil}), do: true

  defp head_check_due?(%{head_checked_at: checked_at}) do
    interval = Application.get_env(:ptc_manager, :deployment_head_check_interval_ms, 60_000)
    System.monotonic_time(:millisecond) - checked_at >= interval
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
