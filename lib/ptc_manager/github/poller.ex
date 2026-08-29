defmodule PtcManager.GitHub.Poller do
  @moduledoc false
  use GenServer

  alias PtcManager.GitHub.Sync

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule_sync()
    {:ok, %{task_ref: nil}}
  end

  @impl true
  def handle_info(:sync, %{task_ref: nil} = state) do
    task =
      Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, &Sync.sync_enabled_repositories/0)

    {:noreply, %{state | task_ref: task.ref}}
  end

  def handle_info({reference, _result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    schedule_sync()
    {:noreply, %{state | task_ref: nil}}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state) do
    schedule_sync()
    {:noreply, %{state | task_ref: nil}}
  end

  defp schedule_sync do
    case Application.get_env(:ptc_manager, :github_sync_interval_ms, 0) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :sync, interval)

      _ ->
        :ok
    end
  end
end
