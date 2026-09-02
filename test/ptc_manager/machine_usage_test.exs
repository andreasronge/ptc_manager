defmodule PtcManager.MachineUsageTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MachineUsage
  alias PtcManager.MachineUsage.Sampler
  alias PtcManager.Operations

  @now ~U[2026-09-02 12:03:10Z]

  test "unknown range keys fall back to the last day" do
    assert MachineUsage.range("nonsense").key == "24h"
    assert MachineUsage.range(nil).key == "24h"
    assert MachineUsage.range("7d").bucket_seconds == 3_600
  end

  test "series averages samples per bucket and reports empty buckets as gaps" do
    record!(~U[2026-09-02 12:02:05Z], cpu_percent: 10.0, active_heavy_agents: 1)
    record!(~U[2026-09-02 12:02:20Z], cpu_percent: 30.0, active_heavy_agents: 1)
    record!(~U[2026-09-02 12:01:00Z], cpu_percent: 50.0, active_light_agents: 2)
    record!(~U[2026-09-02 10:59:59Z], cpu_percent: 99.0)
    record!(~U[2026-09-02 12:03:40Z], cpu_percent: 99.0)

    series = MachineUsage.series("1h", now: @now)

    assert series.range.key == "1h"
    assert series.bucket_seconds == 30
    assert series.from == ~U[2026-09-02 11:03:30Z]
    assert series.to == ~U[2026-09-02 12:03:30Z]
    assert length(series.points) == 120
    assert series.sample_count == 3

    by_time = Map.new(series.points, &{&1.at, &1})

    averaged = by_time[~U[2026-09-02 12:02:00Z]]
    assert averaged.sampled?
    assert_in_delta averaged.cpu, 20.0, 0.001
    assert_in_delta averaged.heavy, 1.0, 0.001
    assert_in_delta averaged.light, 0.0, 0.001

    single = by_time[~U[2026-09-02 12:01:00Z]]
    assert_in_delta single.cpu, 50.0, 0.001
    assert_in_delta single.light, 2.0, 0.001

    gap = by_time[~U[2026-09-02 12:00:00Z]]
    refute gap.sampled?
    assert gap.cpu == nil
    assert gap.heavy == nil
  end

  test "the week view buckets samples per hour" do
    record!(~U[2026-09-01 08:10:00Z], memory_percent: 40.0)
    record!(~U[2026-09-01 08:50:00Z], memory_percent: 60.0)

    series = MachineUsage.series("7d", now: @now)

    assert length(series.points) == 168
    point = Enum.find(series.points, &(&1.at == ~U[2026-09-01 08:00:00Z]))
    assert point.sampled?
    assert_in_delta point.memory, 50.0, 0.001
  end

  test "prune removes samples past the retention window" do
    record!(DateTime.add(@now, -15, :day))
    record!(DateTime.add(@now, -13, :day))

    assert MachineUsage.prune(@now) == 1
    assert MachineUsage.count_samples() == 1
  end

  test "the sampler records host signals together with the occupied slots" do
    worker =
      worker_fixture(%{
        capabilities: %{"herdr" => true, "implementation_slots" => 2},
        last_heartbeat_at: @now
      })

    {:ok, _run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "implementer",
        state: "working",
        started_at: DateTime.add(@now, -60, :second),
        last_heartbeat_at: @now
      })

    snapshot = %{
      cpu_percent: 42.5,
      memory_percent: 61.0,
      disk_percent: 18.2,
      load_average: %{one: 2.5, five: 1.0, fifteen: 0.5}
    }

    MachineUsage.subscribe()

    assert {:ok, sample} = Sampler.record(snapshot, @now)
    assert sample.cpu_percent == 42.5
    assert sample.load_one == 2.5
    assert sample.active_heavy_agents == 1
    assert sample.active_light_agents == 0
    assert sample.active_operations == 0
    assert sample.sampled_at == @now
    assert_receive {:machine_usage_sampled, %{id: id}}
    assert id == sample.id
  end

  test "the sampler tolerates missing host signals" do
    snapshot = %{cpu_percent: nil, memory_percent: nil, disk_percent: nil, load_average: nil}

    assert {:ok, sample} = Sampler.record(snapshot, @now)
    assert sample.cpu_percent == nil
    assert sample.load_one == nil
  end

  defp record!(sampled_at, attrs \\ []) do
    {:ok, sample} =
      attrs
      |> Map.new()
      |> Map.put(:sampled_at, sampled_at)
      |> MachineUsage.record_sample()

    sample
  end
end
