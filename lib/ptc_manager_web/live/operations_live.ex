defmodule PtcManagerWeb.OperationsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.HostMetrics
  alias PtcManager.Herdr.Transcript
  alias PtcManager.Operations
  alias PtcManager.ReviewPolicy

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
     |> assign(:selected_run, nil)
     |> assign(:agent_output, nil)
     |> assign(:agent_output_error, nil)
     |> assign(:agent_output_timer, nil)
     |> load_operations()}
  end

  @impl true
  def handle_params(%{"agent" => id}, _uri, socket) do
    {:noreply, open_agent(socket, id)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> cancel_agent_output_timer()
     |> assign(:selected_run, nil)
     |> assign(:agent_output, nil)
     |> assign(:agent_output_error, nil)}
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

  def handle_info(:agent_output_tick, %{assigns: %{selected_run: nil}} = socket),
    do: {:noreply, assign(socket, :agent_output_timer, nil)}

  def handle_info(:agent_output_tick, socket) do
    {:noreply,
     socket
     |> assign(:agent_output_timer, nil)
     |> load_agent_output()
     |> schedule_agent_output()}
  end

  @impl true
  def handle_event("close_agent", _params, socket),
    do: {:noreply, push_patch(socket, to: ~p"/operations")}

  defp open_agent(socket, id) do
    with {run_id, ""} <- Integer.parse(id),
         %{} = run <- Enum.find(socket.assigns.timeline, &(&1.id == run_id)) do
      socket
      |> cancel_agent_output_timer()
      |> assign(:selected_run, run)
      |> load_agent_output()
      |> schedule_agent_output()
    else
      _failure ->
        socket
        |> cancel_agent_output_timer()
        |> assign(:selected_run, nil)
        |> assign(:agent_output, nil)
        |> assign(:agent_output_error, nil)
        |> put_flash(:error, "That agent run is no longer available.")
    end
  end

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

  def job_review_label(job) do
    count = ReviewPolicy.job_count(job, job.repository)

    "#{count} review #{if(count == 1, do: "pass", else: "passes")}"
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

  def state_classes("waiting"),
    do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"

  def state_classes(state) when state in ["blocked", "unknown"],
    do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"

  def state_classes(state) when state in ["failed", "lost"],
    do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"

  def state_classes(_state), do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"

  def slot_markers(total) when is_integer(total) and total > 0, do: 1..total
  def slot_markers(_total), do: []

  def terminal_refresh_label(%{state: "waiting"}),
    do: "Retained session · refreshes every 5 seconds"

  def terminal_refresh_label(%{ended_at: nil}), do: "Auto-refreshes every 5 seconds"
  def terminal_refresh_label(_run), do: "Final retained terminal snapshot"

  def queued_action_label(%{action_key: "repair_and_merge_pr"}), do: "Fix and merge"
  def queued_action_label(%{action_key: "repair_pr"}), do: "Fix PR"
  def queued_action_label(action), do: String.replace(action.action_key, "_", " ")

  def queued_action_lane_label(action) do
    if Operations.planning_agent_action?(action), do: "Planning lane", else: "Writer lane"
  end

  def queue_age(now, requested_at), do: duration(now, requested_at, nil)

  def phase_timing(
        %{started_at: %DateTime{} = started_at, ended_at: %DateTime{} = ended_at} = run
      ) do
    session_seconds = elapsed_seconds(started_at, ended_at)

    case requested_at(run) do
      %DateTime{} = requested_at ->
        queue_seconds = elapsed_seconds(requested_at, started_at)

        label =
          if queue_seconds > session_seconds do
            "Time before the agent session was the longest recorded phase"
          else
            "The agent session took most recorded time"
          end

        %{
          label: label,
          detail:
            "Before session #{format_duration(queue_seconds)} · session #{format_duration(session_seconds)}. " <>
              "Session time includes coding, tests, reviews, and waits for CI."
        }

      _missing ->
        %{
          label: "Agent session lasted #{format_duration(session_seconds)}",
          detail: "Session time includes coding, tests, reviews, and waits for CI."
        }
    end
  end

  def phase_timing(_run), do: nil

  defp load_operations(socket) do
    workers = Operations.list_workers_with_worktrees()
    active_runs = Operations.list_active_agent_runs()
    waiting_runs = Operations.list_waiting_agent_runs()
    queued_jobs = Operations.list_queued_jobs()
    queued_actions = Operations.list_queued_agent_actions()
    timeline = Operations.list_agent_timeline(40)

    selected_run =
      case socket.assigns.selected_run do
        nil -> nil
        selected -> Enum.find(timeline, &(&1.id == selected.id)) || selected
      end

    active_slot_count =
      workers
      |> Enum.filter(&(&1.status == "online"))
      |> Enum.flat_map(& &1.worktree_allocations)
      |> Enum.count(&Operations.worktree_consumes_execution_slot?/1)

    total_slots = Enum.sum(Enum.map(workers, &worker_capacity/1))

    assign(socket,
      workers: workers,
      active_runs: active_runs,
      waiting_runs: waiting_runs,
      queued_jobs: queued_jobs,
      queued_actions: queued_actions,
      active_slot_count: active_slot_count,
      timeline: timeline,
      selected_run: selected_run,
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

  defp load_agent_output(%{assigns: %{selected_run: run}} = socket) do
    reader = Application.get_env(:ptc_manager, :herdr_transcript_reader, Transcript)

    case reader.read(run) do
      {:ok, ""} ->
        assign(socket,
          agent_output: "The agent terminal is currently empty.",
          agent_output_error: nil
        )

      {:ok, output} ->
        assign(socket, agent_output: output, agent_output_error: nil)

      {:error, message} ->
        assign(socket, agent_output: nil, agent_output_error: message)
    end
  end

  defp schedule_agent_output(%{assigns: %{selected_run: %{ended_at: nil}}} = socket) do
    if connected?(socket) do
      assign(socket, :agent_output_timer, Process.send_after(self(), :agent_output_tick, 5_000))
    else
      socket
    end
  end

  defp schedule_agent_output(socket), do: socket

  defp cancel_agent_output_timer(%{assigns: %{agent_output_timer: nil}} = socket), do: socket

  defp cancel_agent_output_timer(socket) do
    Process.cancel_timer(socket.assigns.agent_output_timer, async: true, info: false)
    assign(socket, :agent_output_timer, nil)
  end

  defp high?(nil, _threshold), do: false
  defp high?(value, threshold), do: value >= threshold
  defp format_number(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp requested_at(%{agent_action: %{requested_at: %DateTime{} = requested_at}}),
    do: requested_at

  defp requested_at(%{job: %{inserted_at: %DateTime{} = inserted_at}}), do: inserted_at
  defp requested_at(_run), do: nil

  defp elapsed_seconds(from, to), do: DateTime.diff(to, from, :second) |> max(0)

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3_600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds),
    do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
end
