defmodule PtcManagerWeb.DeliveryBoardLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog, as: ActionCatalog
  alias PtcManager.MaintainerActions.Poller, as: MaintainerActionPoller
  alias PtcManager.Operations

  @lane_definitions [
    %{
      key: :queued,
      title: "Queued",
      subtitle: "Approved · waiting for capacity",
      color: "bg-sky-400"
    },
    %{
      key: :working,
      title: "In progress",
      subtitle: "Agent, verification, or publishing",
      color: "bg-teal-400"
    },
    %{
      key: :review,
      title: "Review & CI",
      subtitle: "Waiting for checks or merge review",
      color: "bg-violet-400"
    },
    %{
      key: :stuck,
      title: "Needs attention",
      subtitle: "Failure, conflict, or decision",
      color: "bg-amber-400"
    },
    %{
      key: :ready,
      title: "Ready to merge",
      subtitle: "Clean checks and reviewed version",
      color: "bg-emerald-400"
    }
  ]

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Operations.subscribe()
      Process.send_after(self(), :board_tick, 60_000)
    end

    {:ok,
     socket
     |> assign(:page_title, "Delivery board")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:now, DateTime.utc_now())
     |> assign(:lane_definitions, @lane_definitions)
     |> load_board()}
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load_board(socket)}

  def handle_info(:board_tick, socket) do
    Process.send_after(self(), :board_tick, 60_000)
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_event(
        "run-agent-action",
        %{"action-key" => action_key, "target-id" => target_id},
        socket
      ) do
    with {target_id, ""} <- Integer.parse(target_id),
         {:ok, _action} <- MaintainerActions.enqueue(action_key, target_id, socket.assigns.actor) do
      MaintainerActionPoller.wake()

      {:noreply,
       socket
       |> put_flash(:info, "#{ActionCatalog.label(action_key)} queued for an agent.")
       |> load_board()}
    else
      {:error, :agent_action_already_active} ->
        {:noreply, put_flash(socket, :error, "A PR action is already queued or running.")}

      {:error, :pull_request_does_not_need_repair} ->
        {:noreply, put_flash(socket, :info, "GitHub no longer reports a repairable problem.")}

      _error ->
        {:noreply, put_flash(socket, :error, "The repair action could not be queued.")}
    end
  end

  def lane_items(lanes, key), do: Map.get(lanes, key, [])

  def status_label(state) do
    case state do
      "queued" -> "Waiting for agent"
      "starting" -> "Starting agent"
      "working" -> "Agent working"
      "idle" -> "Agent waiting"
      "awaiting_reconciliation" -> "Checking committed work"
      "verifying_result" -> "Verifying branch"
      "ready_for_pr" -> "Waiting for PR"
      "publishing_pr" -> "Publishing PR"
      "pr_open" -> "PR open"
      "publish_blocked" -> "PR blocked"
      value -> String.replace(value, "_", " ")
    end
  end

  def card_age(now, item) do
    started_at = item.active_job.started_at || item.active_job.inserted_at
    seconds = DateTime.diff(now, started_at, :second) |> max(0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  def agent_label(%{agent_run: nil}), do: nil

  def agent_label(%{agent_run: run}) do
    case run.agent_name do
      value when is_binary(value) and value != "" -> value
      _value -> "#{run.role} agent"
    end
  end

  def repair_action(%{publication: nil}), do: nil

  def repair_action(%{publication: publication}) do
    Enum.find(ActionCatalog.pull_request_actions(publication), &(&1.key == "repair_pr"))
  end

  def active_agent_action?(%{state: state}) when state in ["queued", "running", "sync_pending"],
    do: true

  def active_agent_action?(_action), do: false

  def work_state(%{pr_agent_action: %{action_key: "repair_pr"} = action}) do
    if active_agent_action?(action), do: action.state, else: nil
  end

  def work_state(_item), do: nil

  def work_label(%{pr_agent_action: %{action_key: "repair_pr", state: "queued"}}),
    do: "Repair queued"

  def work_label(%{pr_agent_action: %{action_key: "repair_pr", state: "running"}}),
    do: "Agent repairing"

  def work_label(%{pr_agent_action: %{action_key: "repair_pr", state: "sync_pending"}}),
    do: "Checking repaired PR"

  def work_label(_item), do: nil

  def health_badges(item) do
    publication = item.publication

    if publication do
      [
        checks_badge(publication.checks_state),
        merge_badge(publication.mergeability),
        if(publication.draft, do: {"Draft", :muted})
      ]
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  def badge_classes(:good), do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"
  def badge_classes(:bad), do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"
  def badge_classes(:waiting), do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"
  def badge_classes(:muted), do: "bg-white/5 text-slate-400 ring-white/10"

  def next_step(_item, :queued), do: "PtcManager will assign this when a worker slot is free."

  def next_step(item, :working) do
    case item.active_job.state do
      "idle" -> "The agent is idle; check whether it is waiting for input."
      "awaiting_reconciliation" -> "The agent finished; PtcManager is checking its branch."
      "verifying_result" -> "The committed branch is being verified."
      "ready_for_pr" -> "Waiting for the agent-created pull request to appear."
      "publishing_pr" -> "The verified commit is being published."
      _state -> "The assigned agent is implementing and reviewing the change."
    end
  end

  def next_step(item, :review) do
    cond do
      match?(%{publication: %{draft: true}}, item) ->
        "Mark the PR ready when implementation is complete."

      match?(%{publication: %{checks_state: "pending"}}, item) ->
        "CI is still running."

      match?(%{publication: %{checks_state: "unknown"}}, item) ->
        "Waiting for GitHub check status."

      is_nil(item.pr_analysis) ->
        "Prepare a private merge decision from Planning."

      not analysis_fresh?(item) ->
        "The PR changed; prepare a fresh merge decision."

      match?(%{publication: %{mergeability: "unknown"}}, item) ->
        "GitHub is still calculating mergeability."

      true ->
        "Review the remaining PR signals before approval."
    end
  end

  def next_step(item, :stuck) do
    cond do
      work_state(item) == "queued" ->
        "The repair is safely queued and will start when the maintainer agent is free."

      work_state(item) == "running" ->
        "An agent is repairing the existing pull request now."

      work_state(item) == "sync_pending" ->
        "The repair finished; PtcManager is verifying the new PR head against GitHub."

      match?(%{publication: %{mergeability: "conflicting"}}, item) ->
        "Merge conflicts must be resolved by the implementation agent."

      match?(%{publication: %{checks_state: "failure"}}, item) ->
        "One or more CI checks are failing."

      item.pr_analysis && item.pr_analysis.outcome == "merge-blocked" ->
        "The private merge review found blockers."

      item.pr_analysis && item.pr_analysis.outcome == "merge-needs-decision" ->
        "A maintainer decision is required."

      item.active_job.state in ["failed", "lost"] ->
        "The agent stopped before completing the task."

      item.active_job.state == "reconciling" ->
        "PtcManager cannot yet confirm the agent outcome."

      true ->
        "The last delivery step needs maintainer attention."
    end
  end

  def next_step(item, :ready) do
    if item.merge_approval do
      "Approved at this exact PR version; automatic merge is not enabled yet."
    else
      "All observed gates are clean. Review the summary and approve the exact PR version."
    end
  end

  defp load_board(socket) do
    active_runs_by_job =
      Operations.list_active_agent_runs()
      |> Enum.reject(&is_nil(&1.job_id))
      |> Map.new(&{&1.job_id, &1})

    items =
      Operations.dashboard_issues()
      |> Enum.reject(&is_nil(&1.active_job))
      |> Enum.map(&Map.put(&1, :agent_run, Map.get(active_runs_by_job, &1.active_job.id)))

    lanes =
      @lane_definitions
      |> Map.new(&{&1.key, []})
      |> Map.merge(Enum.group_by(items, &lane_for/1))

    assign(socket, lanes: lanes, item_count: length(items))
  end

  defp lane_for(item) do
    cond do
      item.active_job.state == "queued" -> :queued
      stuck?(item) -> :stuck
      ready?(item) -> :ready
      item.active_job.state == "pr_open" -> :review
      true -> :working
    end
  end

  defp stuck?(item) do
    item.active_job.state in ["blocked", "reconciling", "publish_blocked", "failed", "lost"] or
      match?(%{checks_state: "failure"}, item.publication) or
      match?(%{mergeability: "conflicting"}, item.publication) or
      match?(
        %{draft: false, checks_state: checks_state, mergeability: "blocked"}
        when checks_state in ["success", "none"],
        item.publication
      ) or
      match?(
        %{outcome: outcome} when outcome in ["merge-blocked", "merge-needs-decision"],
        item.pr_analysis
      )
  end

  defp ready?(item) do
    item.active_job.state == "pr_open" and
      match?(%{state: "published", pr_state: "open", draft: false}, item.publication) and
      item.publication.checks_state in ["success", "none"] and
      item.publication.mergeability == "mergeable" and
      match?(%{outcome: "merge-ready"}, item.pr_analysis) and analysis_fresh?(item)
  end

  defp analysis_fresh?(%{publication: publication, pr_analysis: analysis})
       when not is_nil(publication) and not is_nil(analysis) do
    analysis.head_sha == publication.remote_head_sha and
      analysis.reviewed_base_sha == publication.remote_base_sha and
      analysis.diff_digest == publication.diff_digest
  end

  defp analysis_fresh?(_item), do: false

  defp checks_badge("success"), do: {"CI passing", :good}
  defp checks_badge("failure"), do: {"CI failing", :bad}
  defp checks_badge("pending"), do: {"CI running", :waiting}
  defp checks_badge("none"), do: {"No CI checks", :muted}
  defp checks_badge(_state), do: {"CI unknown", :muted}

  defp merge_badge("mergeable"), do: {"No conflicts", :good}
  defp merge_badge("conflicting"), do: {"Conflicts", :bad}
  defp merge_badge("blocked"), do: {"Merge blocked", :waiting}
  defp merge_badge(_state), do: {"Mergeability unknown", :muted}
end
