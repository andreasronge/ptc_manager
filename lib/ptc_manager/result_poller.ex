defmodule PtcManager.ResultPoller do
  @moduledoc false
  use GenServer

  alias PtcManager.ResultReconciler

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{task_ref: nil}}
  end

  @impl true
  def handle_info(:reconcile, %{task_ref: nil} = state) do
    if enabled?() do
      task =
        Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, &ResultReconciler.run_once/0)

      {:noreply, %{state | task_ref: task.ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({reference, _result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    schedule()
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    schedule()
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:wake, %{task_ref: nil} = state) do
    if enabled?(), do: send(self(), :reconcile)
    {:noreply, state}
  end

  def handle_cast(:wake, state), do: {:noreply, state}

  defp schedule do
    case {PtcManager.OperationalMode.active?(), interval()} do
      {false, _interval} -> :ok
      {true, interval} when interval > 0 -> Process.send_after(self(), :reconcile, interval)
      _ -> :ok
    end
  end

  defp enabled? do
    PtcManager.OperationalMode.active?() and interval() > 0
  end

  defp interval,
    do: Application.get_env(:ptc_manager, :result_reconcile_interval_ms, 0)
end
