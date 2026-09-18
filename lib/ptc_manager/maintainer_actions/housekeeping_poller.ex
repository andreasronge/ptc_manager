defmodule PtcManager.MaintainerActions.HousekeepingPoller do
  @moduledoc false

  use GenServer

  alias PtcManager.MaintainerActions

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def wake do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :wake)
    :ok
  end

  @impl true
  def init(:ok), do: {:ok, schedule(%{task_ref: nil, timer_ref: nil}, initial_delay())}

  @impl true
  def handle_info(:run, %{task_ref: nil} = state) do
    if enabled?() do
      task =
        Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, fn ->
          PtcManager.DatabaseDiagnostics.with_context("maintainer_actions:housekeeping", fn ->
            MaintainerActions.run_housekeeping()
          end)
        end)

      {:noreply, %{state | task_ref: task.ref, timer_ref: nil}}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def handle_info({reference, _result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, schedule(%{state | task_ref: nil}, interval())}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    {:noreply, schedule(%{state | task_ref: nil}, interval())}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:wake, %{task_ref: nil, timer_ref: nil} = state),
    do: {:noreply, schedule(state, initial_delay())}

  def handle_cast(:wake, state), do: {:noreply, state}

  @doc false
  def initial_delay(interval_ms \\ interval())

  def initial_delay(interval_ms) when is_integer(interval_ms) and interval_ms > 0,
    do: div(interval_ms, 4)

  def initial_delay(_interval_ms), do: 0

  defp schedule(state, delay) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

    if enabled?() do
      %{state | timer_ref: Process.send_after(self(), :run, delay)}
    else
      %{state | timer_ref: nil}
    end
  end

  defp enabled?, do: PtcManager.OperationalMode.active?() and MaintainerActions.enabled?()
  defp interval, do: Application.get_env(:ptc_manager, :agent_action_interval_ms, 5_000)
end
