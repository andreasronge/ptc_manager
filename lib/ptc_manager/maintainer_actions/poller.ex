defmodule PtcManager.MaintainerActions.Poller do
  @moduledoc false
  use GenServer

  alias PtcManager.MaintainerActions

  def child_spec(opts) do
    lane = Keyword.fetch!(opts, :lane)
    index = Keyword.get(opts, :index, 1)

    %{
      id: {__MODULE__, lane, index},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    lane = Keyword.fetch!(opts, :lane)
    index = Keyword.get(opts, :index, 1)
    GenServer.start_link(__MODULE__, {lane, index}, name: name(lane, index))
  end

  def wake do
    Enum.each([:planning, :writing], fn lane ->
      Enum.each(1..8, &wake(name(lane, &1)))
    end)

    :ok
  end

  @impl true
  def init({lane, index}) when lane in [:planning, :writing] do
    {:ok, schedule(%{lane: lane, index: index, task_ref: nil, timer_ref: nil}, 0)}
  end

  @impl true
  def handle_info(:run, %{task_ref: nil} = state) do
    if enabled?() and admitted?(state) do
      task =
        Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, fn ->
          MaintainerActions.run_once(lane: state.lane)
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

  defp name(lane, index),
    do:
      Module.concat(
        PtcManager.MaintainerActions,
        "#{Macro.camelize(to_string(lane))}Poller#{index}"
      )

  defp capacity_key(:planning), do: :light_agent_capacity
  defp capacity_key(:writing), do: :heavy_agent_capacity

  defp admitted?(state) do
    state.index <= Application.get_env(:ptc_manager, capacity_key(state.lane), 1)
  end

  defp wake(name) do
    if Process.whereis(name), do: GenServer.cast(name, :wake)
  end

  defp enabled?, do: PtcManager.OperationalMode.active?() and MaintainerActions.enabled?()
  defp interval, do: Application.get_env(:ptc_manager, :agent_action_interval_ms, 5_000)
end
