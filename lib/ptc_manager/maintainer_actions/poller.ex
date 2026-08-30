defmodule PtcManager.MaintainerActions.Poller do
  @moduledoc false
  use GenServer

  alias PtcManager.MaintainerActions

  @planning_name PtcManager.MaintainerActions.PlanningPoller
  @writing_name PtcManager.MaintainerActions.WritingPoller

  def child_spec(opts) do
    lane = Keyword.fetch!(opts, :lane)

    %{
      id: {__MODULE__, lane},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    GenServer.start_link(__MODULE__, lane, name: name(lane))
  end

  def wake do
    wake(@planning_name)
    wake(@writing_name)
    :ok
  end

  @impl true
  def init(lane) when lane in [:planning, :writing] do
    {:ok, schedule(%{lane: lane, task_ref: nil, timer_ref: nil}, 0)}
  end

  @impl true
  def handle_info(:run, %{task_ref: nil} = state) do
    task =
      Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, fn ->
        MaintainerActions.run_once(lane: state.lane)
      end)

    {:noreply, %{state | task_ref: task.ref, timer_ref: nil}}
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
  def handle_cast(:wake, %{task_ref: nil} = state) do
    {:noreply, schedule(state, 0)}
  end

  def handle_cast(:wake, state), do: {:noreply, state}

  defp schedule(state, delay) do
    cancel_timer(state.timer_ref)

    if enabled?() do
      %{state | timer_ref: Process.send_after(self(), :run, delay)}
    else
      %{state | timer_ref: nil}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(reference), do: Process.cancel_timer(reference, async: true, info: false)

  defp name(:planning), do: @planning_name
  defp name(:writing), do: @writing_name

  defp wake(name) do
    if Process.whereis(name), do: GenServer.cast(name, :wake)
  end

  defp enabled?, do: MaintainerActions.enabled?()
  defp interval, do: Application.get_env(:ptc_manager, :agent_action_interval_ms, 5_000)
end
