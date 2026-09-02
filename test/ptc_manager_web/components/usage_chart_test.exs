defmodule PtcManagerWeb.UsageChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PtcManager.MachineUsage
  alias PtcManagerWeb.UsageChart

  @capacity %{light: 3, heavy: 2, operations: 1}

  test "draws one line segment per contiguous run of samples" do
    usage = usage_with(fn index -> index in [2, 3, 4, 8] end)

    html = render_chart(usage)

    cpu_paths = Regex.scan(~r/class="stroke-teal-400"/, html)
    assert length(cpu_paths) == 2
    assert html =~ ~s(data-range="1h")
    assert html =~ ~s(aria-current="true")
    assert html =~ "Occupied slots · capacity 6"
    assert html =~ "No samples in this bucket"
    assert html =~ "CPU 40.0% · Memory 55.0% · Disk 20.0% · Load 1.50"
    assert html =~ "Heavy 1 · Light 0.5 · Operations 0"
    refute html =~ "No samples yet"
  end

  test "explains an empty history instead of drawing zero load" do
    usage = usage_with(fn _index -> false end)

    html = render_chart(usage)

    assert html =~ "No samples yet"
    refute html =~ ~s(class="stroke-teal-400")
  end

  defp render_chart(usage) do
    render_component(&UsageChart.usage_chart/1,
      id: "chart",
      usage: usage,
      capacity: @capacity,
      range_path: fn key -> "/operations?range=#{key}" end
    )
  end

  defp usage_with(sampled?) do
    range = MachineUsage.range("1h")
    from = ~U[2026-09-02 11:00:00Z]
    count = div(range.seconds, range.bucket_seconds)

    points =
      for index <- 0..(count - 1) do
        at = DateTime.add(from, index * range.bucket_seconds, :second)

        if sampled?.(index) do
          %{
            at: at,
            sampled?: true,
            cpu: 40.0,
            memory: 55.0,
            disk: 20.0,
            load: 1.5,
            heavy: 1.0,
            light: 0.5,
            operations: 0.0
          }
        else
          %{
            at: at,
            sampled?: false,
            cpu: nil,
            memory: nil,
            disk: nil,
            load: nil,
            heavy: nil,
            light: nil,
            operations: nil
          }
        end
      end

    %{
      range: range,
      from: from,
      to: DateTime.add(from, range.seconds, :second),
      now: DateTime.add(from, range.seconds - 10, :second),
      bucket_seconds: range.bucket_seconds,
      points: points,
      sample_count: Enum.count(points, & &1.sampled?)
    }
  end
end
