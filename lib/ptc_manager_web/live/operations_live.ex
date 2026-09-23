defmodule PtcManagerWeb.OperationsLive do
  use PtcManagerWeb, :live_view

  import PtcManagerWeb.UsageChart

  alias PtcManager.CapacitySettings
  alias PtcManager.ResourceOperations
  alias PtcManager.HostMetrics
  alias PtcManager.Herdr.Transcript
  alias PtcManager.MachineUsage
  alias PtcManager.Operations
  alias PtcManager.Operations.AgentHealth
  alias PtcManager.ReviewPolicy
  alias PtcManagerWeb.AgentCancel
  alias PtcManagerWeb.TimeFormat

  embed_templates "operations_live/*"

  @tabs [
    %{action: :index, label: "Now", path: "/operations"},
    %{action: :agents, label: "Agents", path: "/operations/agents"},
    %{action: :performance, label: "Performance", path: "/operations/performance"}
  ]

  @timeline_filters [
    {"all", "All", nil},
    {"active", "Active", ~w(queued starting working idle blocked unknown)},
    {"done", "Done", ~w(done)},
    {"failed", "Failed", ~w(failed lost)},
    {"waiting", "Retained", ~w(waiting)}
  ]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Operations.subscribe()
      MachineUsage.subscribe()
      Process.send_after(self(), :metrics_tick, 1_500)
    end

    {:ok,
     socket
     |> assign(:page_title, "Operations")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:now, DateTime.utc_now())
     |> assign(:metrics, HostMetrics.snapshot())
     |> assign(:selected_run, nil)
     |> assign(:agent_output, nil)
     |> assign(:agent_output_error, nil)
     |> assign(:agent_output_timer, nil)
     |> assign(:range, MachineUsage.range(nil))
     |> assign(:usage, nil)
     |> assign(:timeline_filter, "all")
     |> assign(:include_maintenance?, false)
     |> assign(:cancel_agent_run_id, nil)
     |> assign(
       workers: [],
       active_runs: [],
       waiting_runs: [],
       attention_runs: [],
       queued_jobs: [],
       queued_actions: [],
       resource_operations: [],
       recent_resource_operations: [],
       resource_statistics: nil,
       workspace_setups: [],
       timeline: [],
       timeline_groups: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:range, MachineUsage.range(params["range"]))
     |> assign(:timeline_filter, timeline_filter(params["state"]))
     |> assign(:include_maintenance?, params["maintenance"] == "1")
     |> load_operations()
     |> load_usage()
     |> select_agent(params["agent"])}
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

  def handle_info({:machine_usage_sampled, _sample}, socket),
    do: {:noreply, socket |> assign(:now, DateTime.utc_now()) |> load_usage()}

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
    do: {:noreply, push_patch(socket, to: close_path(socket.assigns))}

  def handle_event("cancel_queued_job", %{"id" => id}, socket) do
    cancel_queued_work(socket, id, &Operations.cancel_queued_job/2, "Implementation job")
  end

  def handle_event("cancel_queued_action", %{"id" => id}, socket) do
    cancel_queued_work(socket, id, &Operations.cancel_queued_agent_action/2, "Agent action")
  end

  def handle_event("confirm-cancel-agent", %{"run-id" => run_id}, socket),
    do: {:noreply, assign(socket, :cancel_agent_run_id, run_id)}

  def handle_event("dismiss-cancel-agent", _params, socket),
    do: {:noreply, assign(socket, :cancel_agent_run_id, nil)}

  def handle_event("cancel-agent", %{"job-id" => job_id}, socket) do
    {kind, message} = AgentCancel.cancel(job_id, socket.assigns.actor)

    {:noreply,
     socket
     |> assign(:cancel_agent_run_id, nil)
     |> put_flash(kind, message)
     |> load_operations()}
  end

  def cancellable_run?(%{job: job} = run), do: AgentCancel.cancellable?(job, run)
  def cancellable_run?(_run), do: false

  def confirming_run_cancel?(run_id, run), do: run_id == Integer.to_string(run.id)

  # Navigation ---------------------------------------------------------------

  def tabs, do: @tabs

  def tab_title(:index), do: "Capacity right now"
  def tab_title(:agents), do: "Agent history"
  def tab_title(:performance), do: "Performance"

  def tab_description(:index),
    do: "Can this machine take more work, and what is running on it at this moment?"

  def tab_description(:agents),
    do: "What the agents have been doing, newest first, with a read-only terminal for each run."

  def tab_description(:performance),
    do:
      "How long expensive commands and workspace preparation take, so slow builds are visible early."

  @doc "Builds a path for an Operations tab, dropping blank query parameters."
  def tab_path(action, params \\ []) do
    base = Enum.find(@tabs, &(&1.action == action)).path

    query =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)
      |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  def range_path(key), do: tab_path(:index, range: range_param(key))

  def filter_path(filter, include_maintenance?) do
    tab_path(:agents,
      state: if(filter != "all", do: filter),
      maintenance: if(include_maintenance?, do: "1")
    )
  end

  def agent_path(assigns, run),
    do: tab_path(assigns.live_action, current_params(assigns) ++ [agent: run.id])

  def close_path(assigns), do: tab_path(assigns.live_action, current_params(assigns))

  defp current_params(%{live_action: :index, range: range}),
    do: [range: range_param(range.key)]

  defp current_params(%{live_action: :agents} = assigns) do
    [
      state: if(assigns.timeline_filter != "all", do: assigns.timeline_filter),
      maintenance: if(assigns.include_maintenance?, do: "1")
    ]
  end

  defp current_params(_assigns), do: []

  defp range_param(key), do: if(key == MachineUsage.default_range_key(), do: nil, else: key)

  def timeline_filters,
    do: Enum.map(@timeline_filters, fn {key, label, _states} -> {key, label} end)

  defp timeline_filter(key) do
    if List.keymember?(@timeline_filters, key, 0), do: key, else: "all"
  end

  defp timeline_states(filter) do
    {_key, _label, states} = List.keyfind(@timeline_filters, filter, 0)
    states
  end

  # Presentation helpers -----------------------------------------------------

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

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :active, :integer, required: true
  attr :capacity, :integer, required: true
  attr :color, :string, required: true
  attr :herdr_online?, :boolean, required: true

  def slot_meter(assigns) do
    ~H"""
    <div id={@id}>
      <p class="text-xs text-slate-400">{@label}</p>
      <p class="mt-1 text-2xl font-semibold">
        {@active}<span class="text-sm text-slate-500">/{@capacity}</span>
      </p>
      <div class="mt-2 flex gap-1">
        <span
          :for={slot <- slot_markers(@capacity)}
          class={[
            "h-1.5 flex-1 rounded-full",
            slot <= @active && @color,
            slot > @active && "bg-white/10"
          ]}
        >
        </span>
      </div>
      <p class="mt-2 text-[11px] leading-4 text-slate-500">
        {agent_slot_detail(@active, @capacity, @herdr_online?)}
      </p>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :now, :any, required: true
  attr :path, :string, required: true

  def run_card(assigns) do
    ~H"""
    <.link
      patch={@path}
      aria-label={"View read-only terminal for #{run_name(@run)}"}
      class="group block w-full rounded-2xl border border-white/10 bg-slate-900/70 p-4 text-left transition hover:border-teal-400/30 hover:bg-slate-900 focus:outline-none focus:ring-2 focus:ring-teal-400/50 sm:p-5"
    >
      <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0">
          <p class="text-sm font-semibold text-slate-100 group-hover:text-teal-200">
            {run_name(@run)} <span class="ml-1 text-xs text-slate-600">View output →</span>
          </p>
          <p class="mt-1 text-sm leading-6 text-slate-300">{run_task(@run)}</p>
        </div>
        <div class="flex shrink-0 flex-wrap items-center gap-1.5">
          <.agent_health_badge run={@run} now={@now} />
          <.work_status state={@run.state} label={@run.state} />
        </div>
      </div>
      <div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-500">
        <span>{@run.worker.name}</span>
        <span>Started {timestamp(@run.started_at)}</span>
        <span>{duration(@now, @run.started_at, @run.ended_at)}</span>
        <span :if={@run.ended_at}>Ended {timestamp(@run.ended_at)}</span>
        <span
          :if={!@run.ended_at && @run.state in ~w(queued starting working unknown)}
          class="inline-flex items-center gap-1.5 text-teal-300"
        >
          <.icon name="hero-arrow-path-mini" class="size-3.5 motion-safe:animate-spin" /> Running now
        </span>
        <span :if={!@run.ended_at && @run.state == "idle"} class="text-slate-400">
          Idle in Herdr
        </span>
        <span :if={!@run.ended_at && @run.state == "blocked"} class="text-amber-300">
          Waiting for input
        </span>
        <span :if={@run.state == "waiting"} class="inline-flex items-center gap-1.5 text-violet-300">
          <.icon name="hero-pause-mini" class="size-3.5" /> Retained with open PR
        </span>
      </div>
    </.link>
    """
  end

  attr :run, :map, required: true
  attr :now, :any, required: true

  def agent_health_badge(assigns) do
    assigns = assign(assigns, :health, AgentHealth.assess(assigns.run, assigns.now))

    ~H"""
    <span
      :if={@health.status != :ended}
      title={@health.detail}
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-1 text-[10px] font-semibold ring-1",
        health_classes(@health.status)
      ]}
    >
      <.icon name={health_icon(@health.status)} class="size-3" />
      {@health.label}
    </span>
    """
  end

  def health_classes(:attention), do: "bg-amber-400/15 text-amber-200 ring-amber-400/25"
  def health_classes(_status), do: "bg-teal-400/10 text-teal-300 ring-teal-400/20"

  def health_icon(:attention), do: "hero-exclamation-triangle-mini"
  def health_icon(_status), do: "hero-check-circle-mini"

  def agent_health(run, now), do: AgentHealth.assess(run, now)

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

  def run_task(_run), do: "Unmanaged Herdr session"

  def duration(now, started_at, ended_at), do: TimeFormat.duration(now, started_at, ended_at)

  def timestamp(datetime), do: Calendar.strftime(datetime, "%d %b · %H:%M")

  @doc "Groups timeline runs by the UTC day they started, newest first."
  def timeline_groups(runs, now) do
    today = DateTime.to_date(now)

    runs
    |> Enum.chunk_by(&DateTime.to_date(&1.started_at))
    |> Enum.map(fn [first | _rest] = group ->
      {day_label(DateTime.to_date(first.started_at), today), group}
    end)
  end

  def day_label(date, today) do
    case Date.diff(today, date) do
      0 -> "Today"
      1 -> "Yesterday"
      _days -> Calendar.strftime(date, "%a %d %b")
    end
  end

  def state_classes(state) when state in ["working", "done"],
    do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"

  def state_classes("waiting"),
    do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"

  def state_classes(state) when state in ["blocked", "unknown"],
    do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"

  def state_classes(state) when state in ["failed", "lost"],
    do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"

  def state_classes(_state), do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"

  def marker_classes(state) when state in ["working", "done"], do: "bg-teal-400"
  def marker_classes(state) when state in ["failed", "lost"], do: "bg-rose-400"
  def marker_classes(state) when state in ["blocked", "unknown"], do: "bg-amber-400"
  def marker_classes("waiting"), do: "bg-violet-400"
  def marker_classes(_state), do: "bg-sky-400"

  def slot_markers(total) when is_integer(total) and total > 0, do: 1..total
  def slot_markers(_total), do: []

  def agent_slot_detail(active, capacity, true) do
    "#{max(capacity - active, 0)} available"
  end

  def agent_slot_detail(_active, _capacity, false), do: "Herdr worker offline · work will queue"

  def operation_agent(%{agent_run: %{agent_name: name}}) when is_binary(name) and name != "",
    do: name

  def operation_agent(%{agent_run: %{role: role}}), do: "#{role} agent"
  def operation_agent(_operation), do: "managed agent"

  def operation_state(%{state: "queued"}), do: "waiting for slot"
  def operation_state(%{state: "starting"}), do: "starting"
  def operation_state(%{state: "running", label: label}), do: label
  def operation_state(%{state: "cancelling"}), do: "stopping"
  def operation_state(%{state: "recovery_pending"}), do: "recovering"
  def operation_state(%{state: state}), do: state

  def operation_slot(%{slot_number: nil}), do: "No slot assigned"
  def operation_slot(%{slot_number: slot}), do: "Operation slot #{slot}"

  def operation_duration(nil), do: "—"
  def operation_duration(milliseconds), do: format_milliseconds(milliseconds)
  def operation_bytes(nil), do: "—"
  def operation_bytes(value), do: bytes(value)
  def operation_rate(nil), do: "—"
  def operation_rate(value), do: percent(value * 100)

  def terminal_refresh_label(%{state: "waiting"}),
    do: "Retained session · refreshes every 5 seconds"

  def terminal_refresh_label(%{ended_at: nil}), do: "Auto-refreshes every 5 seconds"
  def terminal_refresh_label(_run), do: "Final retained terminal snapshot"

  def queued_action_label(%{action_key: "repair_and_merge_pr"}), do: "Approve and merge"
  def queued_action_label(%{action_key: "merge_reviewed_pr"}), do: "Collection merge"
  def queued_action_label(%{action_key: "repair_pr"}), do: "Fix PR"
  def queued_action_label(%{action_key: "daily_digest"}), do: "Daily update"
  def queued_action_label(action), do: String.replace(action.action_key, "_", " ")

  def queued_action_lane_label(action) do
    if Operations.agent_action_resource_class(action) == "light",
      do: "Light work",
      else: "Heavy work"
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
          detail: phase_detail(run, queue_seconds, session_seconds)
        }

      _missing ->
        %{
          label: "Agent session lasted #{format_duration(session_seconds)}",
          detail: "Session time includes coding, tests, reviews, and waits for CI."
        }
    end
  end

  def phase_timing(_run), do: nil

  def workspace_setup_duration(%{workspace_setup_duration_ms: milliseconds})
      when is_integer(milliseconds),
      do: format_milliseconds(milliseconds)

  def workspace_setup_duration(_allocation), do: "—"

  def worktree_creation_duration(%{worktree_created_duration_ms: milliseconds})
      when is_integer(milliseconds),
      do: format_milliseconds(milliseconds)

  def worktree_creation_duration(_allocation), do: "—"

  def workspace_cache_label(%{workspace_setup_cache_state: "hit"}), do: "Warm cache"
  def workspace_cache_label(%{workspace_setup_cache_state: "miss"}), do: "Cold cache"

  def workspace_cache_label(%{workspace_setup_cache_state: "disabled"}),
    do: "Cache unavailable"

  def workspace_cache_label(_allocation), do: nil

  def workspace_setup_phases(%{workspace_setup_phase_durations: durations})
      when is_map(durations) do
    [
      {"cache_restore_ms", "Restore"},
      {"dependencies_ms", "Dependencies"},
      {"asset_tools_ms", "Asset tools"},
      {"cache_publish_ms", "Save cache"}
    ]
    |> Enum.flat_map(fn {key, label} ->
      case durations[key] do
        milliseconds when is_integer(milliseconds) ->
          [{label, format_milliseconds(milliseconds)}]

        _missing ->
          []
      end
    end)
  end

  def workspace_setup_phases(_allocation), do: []

  # Loading ------------------------------------------------------------------

  defp load_operations(socket) do
    now = socket.assigns.now
    workers = Operations.list_workers_with_worktrees()
    active_runs = Operations.list_active_agent_runs()
    waiting_runs = Operations.list_waiting_agent_runs()
    usage = Operations.agent_slot_usage(workers, active_runs, now)
    capacity_setting = CapacitySettings.current()
    available_light_slots = max(capacity_setting.light_agent_capacity - usage.light, 0)
    available_heavy_slots = max(capacity_setting.heavy_agent_capacity - usage.heavy, 0)

    socket
    |> assign(
      workers: workers,
      active_runs: active_runs,
      waiting_runs: waiting_runs,
      attention_runs: AgentHealth.needing_attention(active_runs ++ waiting_runs, now),
      active_light_slots: usage.light,
      active_heavy_slots: usage.heavy,
      light_agent_capacity: capacity_setting.light_agent_capacity,
      heavy_agent_capacity: capacity_setting.heavy_agent_capacity,
      operation_capacity: capacity_setting.operation_capacity,
      available_light_slots: available_light_slots,
      available_heavy_slots: available_heavy_slots,
      available_slots: available_light_slots + available_heavy_slots,
      herdr_online?: usage.herdr_online?
    )
    |> load_tab(socket.assigns.live_action)
    |> refresh_selected_run()
  end

  defp load_tab(socket, :index) do
    assign(socket,
      queued_jobs: Operations.list_queued_jobs(),
      queued_actions: Operations.list_queued_agent_actions(),
      resource_operations: ResourceOperations.list_current(),
      active_operation_slots: ResourceOperations.count_active()
    )
  end

  defp load_tab(socket, :agents) do
    timeline =
      Operations.list_agent_timeline(40,
        states: timeline_states(socket.assigns.timeline_filter),
        include_maintenance: socket.assigns.include_maintenance?
      )

    assign(socket,
      timeline: timeline,
      timeline_groups: timeline_groups(timeline, socket.assigns.now)
    )
  end

  defp load_tab(socket, :performance) do
    assign(socket,
      workspace_setups: Operations.list_recent_workspace_setups(),
      recent_resource_operations: ResourceOperations.list_recent(12),
      resource_statistics: ResourceOperations.statistics()
    )
  end

  defp load_usage(%{assigns: %{live_action: :index}} = socket) do
    assign(socket, :usage, MachineUsage.series(socket.assigns.range.key, now: socket.assigns.now))
  end

  defp load_usage(socket), do: assign(socket, :usage, nil)

  defp loaded_runs(assigns), do: assigns.timeline ++ assigns.active_runs ++ assigns.waiting_runs

  defp refresh_selected_run(%{assigns: %{selected_run: nil}} = socket), do: socket

  defp refresh_selected_run(%{assigns: %{selected_run: selected}} = socket) do
    refreshed = Enum.find(loaded_runs(socket.assigns), &(&1.id == selected.id)) || selected
    assign(socket, :selected_run, refreshed)
  end

  defp select_agent(socket, nil) do
    socket
    |> cancel_agent_output_timer()
    |> assign(:selected_run, nil)
    |> assign(:agent_output, nil)
    |> assign(:agent_output_error, nil)
  end

  defp select_agent(socket, id) do
    with {run_id, ""} <- Integer.parse(id),
         %{} = run <- Enum.find(loaded_runs(socket.assigns), &(&1.id == run_id)) do
      socket
      |> cancel_agent_output_timer()
      |> assign(:selected_run, run)
      |> load_agent_output()
      |> schedule_agent_output()
    else
      _failure ->
        socket
        |> select_agent(nil)
        |> put_flash(:error, "That agent run is no longer available.")
    end
  end

  defp cancel_queued_work(socket, id, cancel, label) do
    with {work_id, ""} <- Integer.parse(id),
         {:ok, _work} <- cancel.(work_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "#{label} cancelled.")
       |> load_operations()}
    else
      _failure ->
        {:noreply,
         socket
         |> put_flash(:error, "That work has already started or left the queue.")
         |> load_operations()}
    end
  end

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

  defp format_duration(seconds), do: TimeFormat.seconds(seconds)

  defp phase_detail(run, queue_seconds, session_seconds) do
    setup = get_in(run, [Access.key(:job), Access.key(:worktree_allocation)])

    "Before session #{format_duration(queue_seconds)}#{setup_breakdown(setup)} · " <>
      "session #{format_duration(session_seconds)}" <>
      ". Session time includes coding, tests, reviews, and waits for CI."
  end

  defp setup_breakdown(%{workspace_setup_state: state} = allocation)
       when state in ["passed", "failed"] do
    " (including worktree #{worktree_creation_duration(allocation)} and " <>
      "repository setup #{workspace_setup_duration(allocation)})"
  end

  defp setup_breakdown(_allocation), do: ""

  defp format_milliseconds(milliseconds) when milliseconds < 1_000,
    do: "#{milliseconds}ms"

  defp format_milliseconds(milliseconds) do
    seconds = milliseconds / 1_000

    if seconds < 60,
      do: :erlang.float_to_binary(seconds, decimals: 1) <> "s",
      else: TimeFormat.seconds(round(seconds))
  end
end
