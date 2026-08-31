defmodule PtcManager.WorktreePoller do
  @moduledoc false
  use GenServer

  alias PtcManager.Worktrees

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok), do: {:ok, schedule(%{task_ref: nil, timer_ref: nil}, interval())}

  @impl true
  def handle_info(:cleanup, %{task_ref: nil} = state) do
    if enabled?() do
      task =
        Task.Supervisor.async_nolink(
          PtcManager.TaskSupervisor,
          &Worktrees.cleanup_terminal_once/0
        )

      {:noreply, %{state | task_ref: task.ref, timer_ref: nil}}
    else
      {:noreply, %{state | timer_ref: nil}}
    end
  end

  def handle_info({reference, _result}, %{task_ref: reference} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, schedule(%{state | task_ref: nil}, interval())}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{task_ref: reference} = state),
    do: {:noreply, schedule(%{state | task_ref: nil}, interval())}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:wake, %{task_ref: nil} = state) do
    {:noreply, schedule(state, 0)}
  end

  def handle_cast(:wake, state), do: {:noreply, state}

  defp schedule(state, delay) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref, async: true, info: false)

    if enabled?() do
      %{state | timer_ref: Process.send_after(self(), :cleanup, delay)}
    else
      %{state | timer_ref: nil}
    end
  end

  defp enabled? do
    PtcManager.OperationalMode.active?() and
      Application.get_env(:ptc_manager, :dispatch_enabled, false) and interval() > 0
  end

  defp interval,
    do: Application.get_env(:ptc_manager, :worktree_reconcile_interval_ms, 30_000)
end
