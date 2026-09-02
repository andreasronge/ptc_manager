defmodule PtcManager.MachineUsage.Sampler do
  @moduledoc """
  Records one machine usage sample per interval and prunes rows past retention.

  The sampler keeps the previous CPU counters so each sample reports the CPU
  share since the last tick. A failed insert is logged and skipped rather than
  restarting the process, so a busy database never turns into a restart loop.
  """

  use GenServer
  require Logger

  alias PtcManager.{HostMetrics, MachineUsage, Operations, ResourceOperations}

  @prune_every_ticks 120

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Records one sample from a host snapshot and the currently occupied slots."
  def record(snapshot, now \\ DateTime.utc_now()) do
    usage = Operations.agent_slot_usage(now)

    MachineUsage.record_sample(%{
      sampled_at: now,
      cpu_percent: snapshot.cpu_percent,
      memory_percent: snapshot.memory_percent,
      disk_percent: snapshot.disk_percent,
      load_one: load_one(snapshot.load_average),
      active_light_agents: usage.light,
      active_heavy_agents: usage.heavy,
      active_operations: ResourceOperations.count_active()
    })
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Application.get_env(:ptc_manager, :machine_usage_sample_interval_ms, 30_000)
      )

    enabled? =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:ptc_manager, :machine_usage_sampling_enabled, true)
      )

    if enabled?, do: Process.send_after(self(), :sample, min(interval_ms, 1_000))

    {:ok, %{interval_ms: interval_ms, cpu_sample: nil, ticks: 0}}
  end

  @impl true
  def handle_info(:sample, state) do
    Process.send_after(self(), :sample, state.interval_ms)
    {:noreply, tick(state)}
  end

  defp tick(state) do
    snapshot = HostMetrics.snapshot(state.cpu_sample)

    case record(snapshot) do
      {:ok, _sample} ->
        :ok

      {:error, changeset} ->
        Logger.warning("machine usage sample rejected: #{inspect(changeset.errors)}")
    end

    if rem(state.ticks, @prune_every_ticks) == 0, do: MachineUsage.prune()

    %{state | cpu_sample: snapshot.cpu_sample, ticks: state.ticks + 1}
  rescue
    error ->
      Logger.warning("machine usage sample failed: #{Exception.message(error)}")
      %{state | ticks: state.ticks + 1}
  end

  defp load_one(%{one: one}) when is_number(one), do: one / 1
  defp load_one(_load), do: nil
end
