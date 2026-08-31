defmodule PtcManager.Dispatch.Poller do
  @moduledoc false
  use GenServer

  alias PtcManager.Dispatch

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok) do
    state = %{task_ref: nil}
    if enabled?(), do: send(self(), :dispatch)
    {:ok, state}
  end

  @impl true
  def handle_info(:dispatch, %{task_ref: nil} = state) do
    if enabled?() do
      task = Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, &Dispatch.run_once/0)
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
    if enabled?(), do: send(self(), :dispatch)
    {:noreply, state}
  end

  def handle_cast(:wake, state), do: {:noreply, state}

  defp schedule do
    if enabled?(), do: Process.send_after(self(), :dispatch, interval())
  end

  defp enabled? do
    PtcManager.OperationalMode.active?() and
      Application.get_env(:ptc_manager, :dispatch_enabled, false)
  end

  defp interval, do: Application.get_env(:ptc_manager, :dispatch_interval_ms, 5_000)
end
