defmodule PtcManagerWeb.OperationsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.HostMetrics
  alias PtcManager.Operations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Operations.subscribe()
      Process.send_after(self(), :metrics_tick, 1_500)
    end

    {:ok,
     socket
     |> assign(:page_title, "Operations")
     |> assign(:now, DateTime.utc_now())
     |> assign(:metrics, HostMetrics.snapshot())
     |> load_operations()}
  end

  @impl true
  def handle_info(:metrics_tick, socket) do
    Process.send_after(self(), :metrics_tick, 5_000)

    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:metrics, HostMetrics.snapshot(socket.assigns.metrics.cpu_sample))
     |> load_operations()}
  end

  def handle_info({:operations_changed, _source}, socket),
    do: {:noreply, load_operations(socket)}

  def percent(nil), do: "—"
  def percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  def bar_width(nil), do: 0
  def bar_width(value), do: value |> round() |> max(0) |> min(100)

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, required: true
  attr :percent, :any, required: true
  attr :color, :string, required: true

  def metric_card(assigns) do
    ~H"""
    <article id={@id} class="rounded-2xl border border-white/10 bg-slate-900/70 p-5">
      <p class="text-xs font-semibold uppercase tracking-wide text-slate-500">{@label}</p>
      <p class="mt-3 text-3xl font-semibold">{@value}</p>
      <p class="mt-2 truncate text-xs text-slate-400">{@detail}</p>
      <div class="mt-4 h-2 overflow-hidden rounded-full bg-white/10">
        <div
          class={["h-full rounded-full transition-[width] duration-500", @color]}
          style={"width: #{bar_width(@percent)}%"}
        >
        </div>
      </div>
    </article>
    """
  end

  def bytes(0), do: "Unavailable"

  def bytes(value) when is_integer(value) do
    cond do
      value >= 1_099_511_627_776 -> format_number(value / 1_099_511_627_776) <> " TB"
      value >= 1_073_741_824 -> format_number(value / 1_073_741_824) <> " GB"
      value >= 1_048_576 -> format_number(value / 1_048_576) <> " MB"
      true -> "#{value} B"
    end
  end

  def load_text(nil), do: "Unavailable"

  def load_text(load) do
    "#{format_number(load.one)} · #{format_number(load.five)} · #{format_number(load.fifteen)}"
  end

  def capacity_tone(%{metrics: metrics, available_slots: available}) do
    cond do
      Enum.any?(
        [metrics.cpu_percent, metrics.memory_percent, metrics.disk_percent],
        &is_nil/1
      ) ->
        :unknown

      high?(metrics.cpu_percent, 85) or high?(metrics.memory_percent, 90) or
          high?(metrics.disk_percent, 92) ->
        :full

      available <= 0 or high?(metrics.cpu_percent, 65) or high?(metrics.memory_percent, 80) or
          high?(metrics.disk_percent, 82) ->
        :busy

      true ->
        :room
    end
  end

  def capacity_label(assigns) do
    case capacity_tone(assigns) do
      :unknown -> "Collecting machine signals before recommending capacity"
      :full -> "At capacity — do not add another agent"
      :busy -> "Hold current capacity and watch the next build"
      :room -> "There is room for another agent slot"
    end
  end

  def capacity_classes(assigns) do
    case capacity_tone(assigns) do
      :unknown -> "border-slate-400/20 bg-slate-400/[0.07] text-slate-300"
      :full -> "border-rose-400/20 bg-rose-400/[0.07] text-rose-200"
      :busy -> "border-amber-400/20 bg-amber-400/[0.07] text-amber-200"
      :room -> "border-teal-400/20 bg-teal-400/[0.07] text-teal-200"
    end
  end

  def run_name(run) do
    case run.agent_name do
      value when is_binary(value) and value != "" -> value
      _value -> String.capitalize(run.role) <> " agent"
    end
  end

  def run_task(%{job: %{issue: issue, repository: repository}}) do
    "#{repository.github_name} ##{issue.number} · #{issue.title}"
  end

  def run_task(%{agent_action: %{target_label: label, action_key: action}}) do
    "#{label} · #{String.replace(action, "_", " ")}"
  end

  def run_task(_run), do: "Repository maintenance"

  def duration(now, started_at, ended_at) do
    seconds = DateTime.diff(ended_at || now, started_at, :second) |> max(0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
    end
  end

  def timestamp(datetime), do: Calendar.strftime(datetime, "%d %b · %H:%M")

  def state_classes(state) when state in ["working", "done"],
    do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"

  def state_classes(state) when state in ["blocked", "unknown"],
    do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"

  def state_classes(state) when state in ["failed", "lost"],
    do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"

  def state_classes(_state), do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"

  def slot_markers(total) when is_integer(total) and total > 0, do: 1..total
  def slot_markers(_total), do: []

  defp load_operations(socket) do
    workers = Operations.list_workers_with_worktrees()
    active_runs = Operations.list_active_agent_runs()

    active_slot_count =
      Enum.count(active_runs, &(&1.role == "implementer" and not is_nil(&1.job_id)))

    total_slots = Enum.sum(Enum.map(workers, &worker_capacity/1))

    assign(socket,
      workers: workers,
      active_runs: active_runs,
      active_slot_count: active_slot_count,
      timeline: Operations.list_agent_timeline(40),
      total_slots: total_slots,
      available_slots: max(total_slots - active_slot_count, 0)
    )
  end

  defp worker_capacity(%{status: "online"} = worker) do
    case worker.capabilities["implementation_slots"] do
      value when is_integer(value) and value > 0 -> value
      _value -> 0
    end
  end

  defp worker_capacity(_worker), do: 0

  defp high?(nil, _threshold), do: false
  defp high?(value, threshold), do: value >= threshold
  defp format_number(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end
