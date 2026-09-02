defmodule PtcManagerWeb.UsageChart do
  @moduledoc """
  Server-rendered SVG timeline of machine usage.

  The geometry is computed in Elixir from the bucketed points that
  `PtcManager.MachineUsage.series/2` returns, so the chart needs no JavaScript
  and stays inside the LiveView diff. Buckets without a sample become gaps, and
  every bucket carries a native tooltip through an SVG title element.
  """

  use Phoenix.Component

  alias PtcManager.MachineUsage

  @width 960
  @left 46
  @right 12
  @host_top 16
  @host_height 140
  @gap 34
  @slot_height 84
  @axis_height 30
  @slot_top @host_top + @host_height + @gap
  @height @slot_top + @slot_height + @axis_height
  @tick_spacing %{"1h" => 600, "24h" => 14_400, "7d" => 86_400}

  @host_series [
    {:cpu, "CPU", "stroke-teal-400", "bg-teal-400"},
    {:memory, "Memory", "stroke-sky-400", "bg-sky-400"},
    {:disk, "Build disk", "stroke-violet-400", "bg-violet-400"}
  ]

  @slot_series [
    {:heavy, "Heavy agents", "fill-teal-400/70", "bg-teal-400"},
    {:light, "Light agents", "fill-sky-400/70", "bg-sky-400"},
    {:operations, "Expensive operations", "fill-violet-400/70", "bg-violet-400"}
  ]

  attr :id, :string, required: true
  attr :usage, :map, required: true, doc: "the result of PtcManager.MachineUsage.series/2"
  attr :capacity, :map, required: true, doc: "light, heavy, and operations slot limits"
  attr :range_path, :any, required: true, doc: "function from a range key to a patch path"

  def usage_chart(assigns) do
    assigns =
      assigns
      |> assign(:chart, build(assigns.usage, assigns.capacity))
      |> assign(
        :host_legend,
        Enum.map(@host_series, fn {_key, label, _stroke, dot} -> {label, dot} end)
      )
      |> assign(
        :slot_legend,
        Enum.map(@slot_series, fn {_key, label, _fill, dot} -> {label, dot} end)
      )

    ~H"""
    <section id={@id} class="rounded-2xl border border-white/10 bg-slate-900/60 p-5">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 class="text-lg font-semibold">Machine usage</h2>
          <p class="mt-1 text-xs text-slate-500">{@chart.subtitle}</p>
        </div>
        <nav
          aria-label="Usage range"
          class="flex w-fit gap-1 rounded-lg border border-white/10 bg-black/20 p-1 text-xs"
        >
          <.link
            :for={range <- MachineUsage.ranges()}
            patch={@range_path.(range.key)}
            aria-current={if range.key == @usage.range.key, do: "true"}
            data-range={range.key}
            class={[
              "rounded-md px-3 py-1.5 font-medium transition",
              range.key == @usage.range.key && "bg-white/10 text-white",
              range.key != @usage.range.key && "text-slate-400 hover:text-white"
            ]}
          >
            {range.label}
          </.link>
        </nav>
      </div>

      <div class="mt-4 overflow-x-auto">
        <svg
          viewBox={"0 0 #{@chart.width} #{@chart.height}"}
          class="h-auto w-full min-w-[36rem] text-slate-500"
          role="img"
          aria-label={"Machine usage over the #{String.downcase(@usage.range.label)}"}
          font-size="11"
          font-family="ui-sans-serif, system-ui, sans-serif"
        >
          <g :for={tick <- @chart.ticks}>
            <line
              x1={tick.x}
              x2={tick.x}
              y1={@chart.host_top}
              y2={@chart.slot_bottom}
              class="stroke-white/[0.06]"
              stroke-width="1"
            />
            <text x={tick.x} y={@chart.axis_y} text-anchor="middle" fill="currentColor">
              {tick.label}
            </text>
          </g>

          <g :for={grid <- @chart.host_grid}>
            <line
              x1={@chart.left}
              x2={@chart.right}
              y1={grid.y}
              y2={grid.y}
              class="stroke-white/10"
              stroke-width="1"
            />
            <text
              :if={grid.label}
              x={@chart.left - 8}
              y={grid.label_y}
              text-anchor="end"
              fill="currentColor"
            >
              {grid.label}
            </text>
          </g>

          <g :for={grid <- @chart.slot_grid}>
            <line
              x1={@chart.left}
              x2={@chart.right}
              y1={grid.y}
              y2={grid.y}
              class="stroke-white/10"
              stroke-width="1"
            />
            <text
              :if={grid.label}
              x={@chart.left - 8}
              y={grid.label_y}
              text-anchor="end"
              fill="currentColor"
            >
              {grid.label}
            </text>
          </g>

          <text x={@chart.left} y={@chart.host_top - 5} fill="currentColor" class="font-semibold">
            Host load
          </text>
          <text x={@chart.left} y={@chart.slot_top - 5} fill="currentColor" class="font-semibold">
            Occupied slots · capacity {@chart.capacity_total}
          </text>

          <path
            :for={{path, class} <- @chart.slot_paths}
            d={path}
            class={class}
            stroke="none"
          />

          <line
            x1={@chart.left}
            x2={@chart.right}
            y1={@chart.capacity_y}
            y2={@chart.capacity_y}
            class="stroke-white/40"
            stroke-width="1"
            stroke-dasharray="4 3"
          />

          <path
            :for={{path, class} <- @chart.host_paths}
            d={path}
            fill="none"
            class={class}
            stroke-width="1.75"
            stroke-linejoin="round"
            stroke-linecap="round"
            vector-effect="non-scaling-stroke"
          />

          <rect
            :for={cell <- @chart.cells}
            x={cell.x}
            y={@chart.host_top}
            width={cell.width}
            height={@chart.slot_bottom - @chart.host_top}
            class="fill-transparent hover:fill-white/5"
          >
            <title>{cell.title}</title>
          </rect>

          <text
            :if={@usage.sample_count == 0}
            x={(@chart.left + @chart.right) / 2}
            y={@chart.host_top + @chart.host_height / 2}
            text-anchor="middle"
            fill="currentColor"
            font-size="13"
          >
            No samples yet. Usage history starts a few minutes after this version is deployed.
          </text>
        </svg>
      </div>

      <div class="mt-3 flex flex-wrap gap-x-5 gap-y-2 text-xs text-slate-400">
        <span :for={{label, dot} <- @host_legend} class="inline-flex items-center gap-1.5">
          <span class={["h-0.5 w-4 rounded-full", dot]}></span> {label}
        </span>
        <span class="text-slate-700">|</span>
        <span :for={{label, dot} <- @slot_legend} class="inline-flex items-center gap-1.5">
          <span class={["size-2.5 rounded-sm opacity-70", dot]}></span> {label}
        </span>
      </div>
    </section>
    """
  end

  @doc false
  def build(usage, capacity) do
    points = usage.points
    count = length(points)
    plot_width = @width - @left - @right
    step = plot_width / count
    range_seconds = DateTime.diff(usage.to, usage.from, :second)
    from_unix = DateTime.to_unix(usage.from)
    capacity_total = capacity.light + capacity.heavy + capacity.operations

    observed_max =
      points
      |> Enum.map(&slot_total/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0.0 end)

    slot_max = max(capacity_total, Float.ceil(observed_max / 1)) |> max(1)

    x_mid = fn index -> @left + (index + 0.5) * step end
    x_edge = fn index -> @left + index * step end
    host_y = fn value -> @host_top + @host_height - value / 100 * @host_height end
    slot_y = fn value -> @slot_top + @slot_height - value / slot_max * @slot_height end

    %{
      width: @width,
      height: @height,
      left: @left,
      right: @width - @right,
      host_top: @host_top,
      host_height: @host_height,
      slot_top: @slot_top,
      slot_bottom: @slot_top + @slot_height,
      axis_y: @slot_top + @slot_height + 18,
      capacity_total: capacity_total,
      capacity_y: format(slot_y.(capacity_total)),
      subtitle: subtitle(usage),
      ticks: ticks(usage, from_unix, range_seconds, plot_width),
      host_grid:
        Enum.map([0, 25, 50, 75, 100], fn value ->
          %{
            y: format(host_y.(value)),
            label_y: format(host_y.(value) + 4),
            label: if(rem(value, 50) == 0, do: "#{value}%")
          }
        end),
      slot_grid: slot_grid(slot_max, slot_y),
      host_paths: host_paths(points, x_mid, host_y),
      slot_paths: slot_paths(points, x_edge, slot_y),
      cells: cells(points, usage, x_edge, step)
    }
  end

  defp subtitle(%{sample_count: 0}), do: "Sampled every 30 seconds · times in UTC"

  defp subtitle(usage) do
    "Averages per #{bucket_label(usage.bucket_seconds)} from #{usage.sample_count} samples · times in UTC"
  end

  defp bucket_label(30), do: "30 seconds"
  defp bucket_label(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} minutes"
  defp bucket_label(_seconds), do: "hour"

  defp ticks(usage, from_unix, range_seconds, plot_width) do
    spacing = Map.fetch!(@tick_spacing, usage.range.key)
    first = div(from_unix + spacing - 1, spacing) * spacing
    to_unix = from_unix + range_seconds

    first
    |> Stream.iterate(&(&1 + spacing))
    |> Enum.take_while(&(&1 <= to_unix))
    |> Enum.map(fn unix ->
      %{
        x: format(@left + (unix - from_unix) / range_seconds * plot_width),
        label: tick_label(usage.range.key, DateTime.from_unix!(unix))
      }
    end)
  end

  defp tick_label("7d", datetime), do: Calendar.strftime(datetime, "%a %d")
  defp tick_label(_range, datetime), do: Calendar.strftime(datetime, "%H:%M")

  defp slot_grid(slot_max, slot_y) do
    step = if slot_max <= 8, do: 1, else: Float.ceil(slot_max / 4)

    0
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= slot_max))
    |> Enum.map(fn value ->
      %{
        y: format(slot_y.(value)),
        label_y: format(slot_y.(value) + 4),
        label: if(value == 0 or value == slot_max, do: format_count(value))
      }
    end)
  end

  defp host_paths(points, x_mid, host_y) do
    for {key, _label, class, _dot} <- @host_series,
        segment <- segments(points, &Map.get(&1, key)) do
      {line_path(segment, x_mid, host_y), class}
    end
  end

  defp slot_paths(points, x_edge, slot_y) do
    layers = [
      {:heavy, fn _point -> 0.0 end, &(&1.heavy || 0.0)},
      {:light, &(&1.heavy || 0.0), &((&1.heavy || 0.0) + (&1.light || 0.0))},
      {:operations, &((&1.heavy || 0.0) + (&1.light || 0.0)), &slot_total/1}
    ]

    for {key, lower, upper} <- layers,
        {_key, _label, class, _dot} = Enum.find(@slot_series, &(elem(&1, 0) == key)),
        segment <-
          segments(points, fn point -> if point.sampled?, do: {lower.(point), upper.(point)} end) do
      {area_path(segment, x_edge, slot_y), class}
    end
  end

  defp slot_total(%{sampled?: false}), do: nil

  defp slot_total(point),
    do: (point.heavy || 0.0) + (point.light || 0.0) + (point.operations || 0.0)

  defp segments(points, value_fun) do
    points
    |> Enum.with_index(fn point, index -> {index, value_fun.(point)} end)
    |> Enum.chunk_by(fn {_index, value} -> is_nil(value) end)
    |> Enum.reject(fn [{_index, value} | _rest] -> is_nil(value) end)
  end

  defp line_path([{index, value}], x_fun, y_fun) do
    point = "#{format(x_fun.(index))} #{format(y_fun.(value))}"
    "M#{point} L#{point}"
  end

  defp line_path([{index, value} | rest], x_fun, y_fun) do
    Enum.reduce(rest, "M#{format(x_fun.(index))} #{format(y_fun.(value))}", fn {i, v}, path ->
      path <> " L#{format(x_fun.(i))} #{format(y_fun.(v))}"
    end)
  end

  defp area_path(segment, x_edge, slot_y) do
    upper =
      Enum.flat_map(segment, fn {index, {_lower, upper}} ->
        y = format(slot_y.(upper))
        ["#{format(x_edge.(index))} #{y}", "#{format(x_edge.(index + 1))} #{y}"]
      end)

    lower =
      segment
      |> Enum.reverse()
      |> Enum.flat_map(fn {index, {lower, _upper}} ->
        y = format(slot_y.(lower))
        ["#{format(x_edge.(index + 1))} #{y}", "#{format(x_edge.(index))} #{y}"]
      end)

    "M" <> Enum.join(upper ++ lower, " L") <> " Z"
  end

  defp cells(points, usage, x_edge, step) do
    Enum.with_index(points, fn point, index ->
      %{
        x: format(x_edge.(index)),
        width: format(step),
        title: cell_title(point, usage.bucket_seconds)
      }
    end)
  end

  defp cell_title(%{sampled?: false} = point, bucket_seconds) do
    "#{bucket_window(point.at, bucket_seconds)}\nNo samples in this bucket"
  end

  defp cell_title(point, bucket_seconds) do
    [
      bucket_window(point.at, bucket_seconds),
      "CPU #{format_percent(point.cpu)} · Memory #{format_percent(point.memory)} · Disk #{format_percent(point.disk)} · Load #{format_load(point.load)}",
      "Heavy #{format_count(point.heavy)} · Light #{format_count(point.light)} · Operations #{format_count(point.operations)}"
    ]
    |> Enum.join("\n")
  end

  defp bucket_window(at, bucket_seconds) do
    finish = DateTime.add(at, bucket_seconds, :second)

    "#{Calendar.strftime(at, "%d %b %H:%M")}–#{Calendar.strftime(finish, "%H:%M")} UTC"
  end

  defp format_percent(nil), do: "—"
  defp format_percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  defp format_load(nil), do: "—"
  defp format_load(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp format_count(nil), do: "—"
  defp format_count(value) when is_integer(value), do: Integer.to_string(value)

  defp format_count(value) do
    if value == Float.round(value),
      do: Integer.to_string(round(value)),
      else: :erlang.float_to_binary(value, decimals: 1)
  end

  defp format(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end
