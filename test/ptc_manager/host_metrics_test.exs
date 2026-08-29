defmodule PtcManager.HostMetricsTest do
  use ExUnit.Case, async: true

  alias PtcManager.HostMetrics

  test "returns a bounded snapshot even when an operating-system signal is unavailable" do
    first = HostMetrics.snapshot()
    second = HostMetrics.snapshot(first.cpu_sample)

    assert %DateTime{} = first.captured_at
    assert is_integer(first.cores) and first.cores > 0
    assert is_integer(first.memory_used_bytes) and first.memory_used_bytes >= 0
    assert is_integer(first.memory_total_bytes) and first.memory_total_bytes >= 0
    assert first.disk_used_bytes >= 0
    assert first.disk_total_bytes >= 0
    assert is_binary(first.disk_path)

    for value <- [second.cpu_percent, second.memory_percent, second.disk_percent],
        not is_nil(value) do
      assert value >= 0.0 and value <= 100.0
    end
  end
end
