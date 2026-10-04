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
    PtcManager.MaintainerActions.HousekeepingPoller.wake()
    Enum.each(1..16, &wake(name(:planning, &1)))
    Enum.each(1..16, &wake(name(:writing, &1)))

    :ok
  end

  @impl true
  def init({lane, index}) when lane in [:planning, :writing] do
    state = %{lane: lane, index: index, task_ref: nil, timer_ref: nil}
    {:ok, schedule(state, initial_delay(lane, index, interval()))}
  end

  @impl true
  def handle_info(:run, %{task_ref: nil} = state) do
    if enabled?() and admitted?(state) do
      task =
        Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, fn ->
          PtcManager.DatabaseDiagnostics.with_context(
            "maintainer_actions:#{state.lane}:#{state.index}",
            fn ->
              MaintainerActions.run_once(
                lane: state.lane,
                resource_class: resource_class(state.lane, state.index),
                housekeeping: false
              )
            end
          )
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
  def handle_cast(:wake, %{task_ref: nil, timer_ref: nil} = state) do
    {:noreply, schedule(state, initial_delay(state.lane, state.index, interval()))}
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

  defp admitted?(state) do
    state.index <= lane_capacity(state.lane)
  end

  defp lane_capacity(lane) when lane in [:planning, :writing],
    do: configured_capacity(:light) + configured_capacity(:heavy)

  @doc false
  def resource_class(lane, index)
      when lane in [:planning, :writing] and is_integer(index) and index > 0 do
    if index <= configured_capacity(:light), do: "light", else: "heavy"
  end

  @doc false
  def initial_delay(lane, index, interval_ms)
      when lane in [:planning, :writing] and is_integer(index) and index > 0 and
             is_integer(interval_ms) and interval_ms > 0 do
    capacity = max(lane_capacity(lane), 1)
    lane_offset = if lane == :planning, do: 0, else: 1
    slot = rem((index - 1) * 2 + lane_offset, capacity * 2)
    div(interval_ms * slot, capacity * 2)
  end

  def initial_delay(_lane, _index, _interval_ms), do: 0

  defp configured_capacity(:light),
    do: Application.get_env(:ptc_manager, :light_agent_capacity, 2)

  defp configured_capacity(:heavy),
    do: Application.get_env(:ptc_manager, :heavy_agent_capacity, 1)

  defp wake(name) do
    if Process.whereis(name), do: GenServer.cast(name, :wake)
  end

  defp enabled?, do: PtcManager.OperationalMode.active?() and MaintainerActions.enabled?()
  defp interval, do: Application.get_env(:ptc_manager, :agent_action_interval_ms, 5_000)
end
