defmodule PtcManager.PublisherPoller do
  @moduledoc false
  use GenServer

  alias PtcManager.Publisher

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def wake, do: GenServer.cast(__MODULE__, :wake)

  @impl true
  def init(:ok) do
    {:ok, schedule(%{task_ref: nil, timer_ref: nil}, 0)}
  end

  @impl true
  def handle_info(:publish, %{task_ref: nil} = state) do
    if enabled?() do
      task =
        PtcManager.DatabaseDiagnostics.async_nolink(
          PtcManager.TaskSupervisor,
          "publication",
          &Publisher.run_once/0
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
      %{state | timer_ref: Process.send_after(self(), :publish, delay)}
    else
      %{state | timer_ref: nil}
    end
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(reference), do: Process.cancel_timer(reference, async: true, info: false)

  defp enabled? do
    PtcManager.OperationalMode.reconciliation_allowed?() and
      Application.get_env(:ptc_manager, :publication_enabled, false)
  end

  defp interval, do: Application.get_env(:ptc_manager, :publication_interval_ms, 5_000)
end
