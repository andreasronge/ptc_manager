defmodule PtcManager.GitHub.Poller do
  @moduledoc false
  use GenServer

  alias PtcManager.GitHub.Sync
  alias PtcManager.PollerWake

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok) do
    state = %{task_ref: nil, timer_ref: nil}
    {:ok, schedule_sync(state)}
  end

  @impl true
  def handle_info(:sync, %{task_ref: nil} = state) do
    state = PollerWake.clear_timer(state)

    if enabled?() do
      task =
        Task.Supervisor.async_nolink(
          PtcManager.TaskSupervisor,
          &Sync.sync_enabled_repositories/0
        )

      {:noreply, %{state | task_ref: task.ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:sync, state), do: {:noreply, PollerWake.clear_timer(state)}

  def handle_info({reference, _result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, schedule_sync(%{state | task_ref: nil})}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    {:noreply, schedule_sync(%{state | task_ref: nil})}
  end

  @impl true
  def handle_cast(:wake, state), do: PollerWake.handle(state, enabled?(), :sync)

  defp schedule_sync(state),
    do: PollerWake.schedule(state, enabled?(), :sync, interval())

  defp enabled?, do: PtcManager.OperationalMode.active?() and interval() > 0

  defp interval do
    case Application.get_env(:ptc_manager, :github_sync_interval_ms, 0) do
      interval when is_integer(interval) and interval > 0 ->
        interval

      _ ->
        0
    end
  end
end
