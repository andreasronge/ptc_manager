defmodule PtcManager.PublicationStatusPoller do
  @moduledoc false
  use GenServer

  alias PtcManager.PublicationStatusReconciler

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok), do: {:ok, schedule(%{task_ref: nil, timer_ref: nil}, 0)}

  @impl true
  def handle_info(:reconcile_pr, %{task_ref: nil} = state) do
    if enabled?() do
      task =
        Task.Supervisor.async_nolink(
          PtcManager.TaskSupervisor,
          &PublicationStatusReconciler.run_once/0
        )

      {:noreply, %{state | task_ref: task.ref, timer_ref: nil}}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def handle_info({reference, result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, schedule(%{state | task_ref: nil}, next_delay(result))}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    {:noreply, schedule(%{state | task_ref: nil}, interval())}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:wake, %{task_ref: nil} = state) do
    cancel_timer(state.timer_ref)
    if enabled?(), do: send(self(), :reconcile_pr)
    {:noreply, %{state | timer_ref: nil}}
  end

  def handle_cast(:wake, state), do: {:noreply, state}

  defp schedule(state, delay) do
    cancel_timer(state.timer_ref)

    if enabled?() do
      %{state | timer_ref: Process.send_after(self(), :reconcile_pr, delay)}
    else
      %{state | timer_ref: nil}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(reference), do: Process.cancel_timer(reference, async: true, info: false)

  @doc false
  def next_delay({:retry_after, delay_ms}) when is_integer(delay_ms) and delay_ms > 0,
    do: max(delay_ms, interval())

  def next_delay(_result), do: interval()

  defp enabled? do
    PtcManager.OperationalMode.reconciliation_allowed?() and
      (Application.get_env(:ptc_manager, :pr_reconcile_enabled, false) or
         PtcManager.Publications.agent_reconciliation_needed?())
  end

  defp interval, do: Application.get_env(:ptc_manager, :publication_status_interval_ms, 60_000)
end
