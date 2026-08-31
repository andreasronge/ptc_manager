defmodule PtcManager.DailyDigests.Scheduler do
  @moduledoc false

  use GenServer
  require Logger

  alias PtcManager.DailyDigests

  @default_interval_ms 60_000
  @minimum_interval_ms 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, schedule(%{timer_ref: nil}, 0)}
  end

  @impl true
  def handle_info(:tick, state) do
    case DailyDigests.enqueue_due() do
      {:ok, _digests} -> :ok
      {:error, reason} -> Logger.warning("Daily update scheduling failed: #{inspect(reason)}")
    end

    {:noreply, schedule(%{state | timer_ref: nil}, interval())}
  end

  defp schedule(state, delay) do
    if DailyDigests.enabled?(),
      do: %{state | timer_ref: Process.send_after(self(), :tick, delay)},
      else: state
  end

  @doc false
  def interval do
    case Application.get_env(:ptc_manager, :daily_digest_interval_ms, @default_interval_ms) do
      value when is_integer(value) and value >= @minimum_interval_ms -> value
      _invalid -> @default_interval_ms
    end
  end
end
