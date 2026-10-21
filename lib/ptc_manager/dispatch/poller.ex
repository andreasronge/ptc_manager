defmodule PtcManager.Dispatch.Poller do
  @moduledoc false
  use GenServer

  require Logger

  alias PtcManager.Dispatch

  @max_backoff_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok) do
    state = %{task_ref: nil, last_error: nil, delay_ms: nil}
    if enabled?(), do: send(self(), :dispatch)
    {:ok, state}
  end

  @impl true
  def handle_info(:dispatch, %{task_ref: nil} = state) do
    if enabled?() do
      task =
        PtcManager.DatabaseDiagnostics.async_nolink(
          PtcManager.TaskSupervisor,
          "dispatch",
          &Dispatch.run_once/0
        )

      {:noreply, %{state | task_ref: task.ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({reference, result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, %{observe(result, state) | task_ref: nil} |> schedule()}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{task_ref: reference} = state) do
    {:noreply, %{observe({:error, {:crashed, reason}}, state) | task_ref: nil} |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:wake, %{task_ref: nil} = state) do
    if enabled?(), do: send(self(), :dispatch)
    {:noreply, state}
  end

  def handle_cast(:wake, state), do: {:noreply, state}

  # A failure is logged once when it changes and its recovery once; the same
  # failure again backs off, doubling up to a minute.
  @doc false
  def observe({:error, reason}, %{last_error: reason, delay_ms: delay} = state),
    do: %{state | delay_ms: min(delay * 2, @max_backoff_ms)}

  def observe({:error, reason}, state) do
    Logger.warning("Dispatch stopped before leasing a job: #{inspect(reason)}")
    %{state | last_error: reason, delay_ms: interval()}
  end

  def observe(_result, %{last_error: nil} = state), do: %{state | delay_ms: interval()}

  def observe(_result, state) do
    Logger.info("Dispatch recovered after: #{inspect(state.last_error)}")
    %{state | last_error: nil, delay_ms: interval()}
  end

  defp schedule(state) do
    if enabled?(), do: Process.send_after(self(), :dispatch, state.delay_ms || interval())
    state
  end

  defp enabled? do
    PtcManager.OperationalMode.active?() and
      Application.get_env(:ptc_manager, :dispatch_enabled, false)
  end

  defp interval, do: Application.get_env(:ptc_manager, :dispatch_interval_ms, 5_000)
end
