defmodule PtcManagerWeb.DeliveryBoardLive do
  use PtcManagerWeb, :live_view

  import PtcManagerWeb.RetrospectiveComponents, only: [retrospective: 1]

  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog, as: ActionCatalog
  alias PtcManager.MaintainerActions.Poller, as: MaintainerActionPoller
  alias PtcManager.Operations
  alias PtcManager.Operations.AgentHealth
  alias PtcManager.Operations.DeliveryLane
  alias PtcManager.Operations.PrPublication
  alias PtcManager.Operations.StopReport
  alias PtcManagerWeb.AgentCancel
  alias PtcManagerWeb.RetrospectiveComponents

  @lane_definitions [
    %{key: :queued, subtitle: "Approved · waiting for capacity", color: "bg-sky-400"},
    %{key: :working, subtitle: "Agent, verification, or publishing", color: "bg-teal-400"},
    %{key: :stuck, subtitle: "Failure, conflict, or decision", color: "bg-amber-400"},
    %{key: :ready, subtitle: "Clean checks and no conflicts", color: "bg-emerald-400"}
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
     |> assign(:selected_repository, nil)
     |> assign(:repositories, Operations.list_repositories())
     |> assign(:now, DateTime.utc_now())
     |> assign(:lane_definitions, @lane_definitions)
     |> assign(:cancel_agent_job_id, nil)
     |> assign(:abandon_job_id, nil)
     |> load_board()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    repositories = Operations.list_repositories()

    selected =
      case params do
        %{"repo" => key} ->
          if Enum.any?(repositories, &(repository_key(&1) == key)), do: key, else: nil

        _params ->
          nil
      end

    {:noreply,
     socket
     |> assign(:repositories, repositories)
     |> assign(:selected_repository, selected)
     |> load_board()}
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load_board(socket)}

  def handle_info(:board_tick, socket) do
    Process.send_after(self(), :board_tick, 60_000)
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("confirm-cancel-agent", %{"job-id" => job_id}, socket) do
    {:noreply, assign(socket, :cancel_agent_job_id, job_id)}
  end

  def handle_event("dismiss-cancel-agent", _params, socket) do
    {:noreply, assign(socket, :cancel_agent_job_id, nil)}
  end

  def handle_event("cancel-agent", %{"job-id" => job_id}, socket) do
    {kind, message} = AgentCancel.cancel(job_id, socket.assigns.actor)

    {:noreply,
     socket
     |> assign(:cancel_agent_job_id, nil)
     |> put_flash(kind, message)
     |> load_board()}
  end

  def handle_event("retry-stopped-job", %{"job-id" => job_id}, socket) do
    with {job_id, ""} <- Integer.parse(job_id),
         {:ok, _job} <- Operations.retry_stopped_job(job_id, socket.assigns.actor) do
      PtcManager.Dispatch.Poller.wake()

      {:noreply,
       socket
       |> put_flash(:info, "Queued a fresh attempt with the same approval and review count.")
       |> load_board()}
    else
      {:error, :job_not_stopped} ->
        {:noreply,
         socket |> put_flash(:info, "That attempt was already handled.") |> load_board()}

      _error ->
        {:noreply, put_flash(socket, :error, "A fresh attempt could not be queued.")}
    end
  end

  def handle_event("ask-on-issue", %{"job-id" => job_id}, socket) do
    with {job_id, ""} <- Integer.parse(job_id),
         {:ok, _action} <-
           MaintainerActions.enqueue_blocked_issue_review(job_id, socket.assigns.actor) do
      MaintainerActionPoller.wake()

      {:noreply,
       socket
       |> put_flash(
         :info,
         "An agent will put the blocker on the GitHub issue for a decision."
       )
       |> load_board()}
    else
      {:error, :agent_action_already_active} ->
        {:noreply, put_flash(socket, :error, "An action is already queued for that issue.")}

      {:error, :recovery_not_offered} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The agent judged this unsafe. Read its evidence before asking on the issue."
         )}

      {:error, :job_not_stopped} ->
        {:noreply,
         socket |> put_flash(:info, "That attempt was already handled.") |> load_board()}

      _error ->
        {:noreply, put_flash(socket, :error, "The issue could not be updated.")}
    end
  end

  def handle_event("confirm-abandon", %{"job-id" => job_id}, socket) do
    {:noreply, assign(socket, :abandon_job_id, job_id)}
  end

  def handle_event("dismiss-abandon", _params, socket) do
    {:noreply, assign(socket, :abandon_job_id, nil)}
  end

  def handle_event("abandon-job", %{"job-id" => job_id}, socket) do
    socket = assign(socket, :abandon_job_id, nil)

    with {job_id, ""} <- Integer.parse(job_id),
         {:ok, _job} <- Operations.abandon_stuck_job(job_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Abandoned. Its worktree is kept on Operations if you need it.")
       |> load_board()}
    else
      {:error, :verification_in_progress} ->
        {:noreply,
         socket
         |> put_flash(:info, "A check is running right now. Try again when it finishes.")
         |> load_board()}

      {:error, :pull_request_open} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "This job already has a pull request. Close or merge it on GitHub instead."
         )
         |> load_board()}

      {:error, :job_not_abandonable} ->
        {:noreply, socket |> put_flash(:info, "That job has already moved on.") |> load_board()}

      _error ->
        {:noreply, put_flash(socket, :error, "That job could not be abandoned.")}
    end
  end

  def handle_event("acknowledge-stop", %{"job-id" => job_id}, socket) do
    with {job_id, ""} <- Integer.parse(job_id),
         {:ok, _job} <- Operations.acknowledge_job_stop(job_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Set aside. Its worktree is still on Operations if you need it.")
       |> load_board()}
    else
      _error ->
        {:noreply,
         socket |> put_flash(:info, "That attempt was already handled.") |> load_board()}
    end
  end

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

      {:error, :pull_request_not_ready_for_retrospective} ->
        {:noreply, put_flash(socket, :info, "The PR is no longer ready for a retrospective.")}

      _error ->
        {:noreply, put_flash(socket, :error, "The PR action could not be queued.")}
    end
  end

  def handle_event(
        "create-retrospective-issue",
        %{"source-action-id" => source_action_id, "suggestion-index" => suggestion_index},
        socket
      ) do
    {kind, message} =
      RetrospectiveComponents.queue_issue(
        source_action_id,
        suggestion_index,
        socket.assigns.actor
      )

    {:noreply, socket |> put_flash(kind, message) |> load_board()}
  end

  def lane_items(lanes, key) do
    lanes
    |> Map.get(key, [])
    |> Enum.sort_by(&lane_item_sort_key/1)
  end

  defp lane_item_sort_key(item) do
    started_at =
      case item.started_at do
        %DateTime{} = value -> DateTime.to_unix(value, :microsecond)
        _ -> 0
      end

    {
      started_at,
      repository_label(item),
      item.number || 0,
      card_id(item)
    }
  end

  def linked_issues(item), do: Map.get(item, :linked_issues, [])

  def cancellable_agent?(item), do: item.managed? and AgentCancel.cancellable?(item)

  @doc """
  True when PtcManager owns this job's phase and cannot finish it on its own.

  These are the phases Cancel agent refuses, because there is no agent to
  cancel. Without a way out they can repeat the same failure forever.

  `reconciling` is not one of them: it can mean an agent whose remote state is
  unknown, and Cancel agent, which closes the pane, is the right tool there. Nor
  is any card that already has a pull request, which abandoning would orphan.
  """
  def abandonable?(%{managed?: true, active_job: %{state: state}} = item)
      when state in ~w(awaiting_reconciliation verifying_result publish_blocked),
      do: not verification_running?(item) and not published?(item)

  def abandonable?(_item), do: false

  # A blocked publication normally has a row with no pull request yet; only an
  # actual PR number means there is something abandoning would orphan.
  defp published?(%{publication: %{pr_number: number}}) when is_integer(number), do: true
  defp published?(_item), do: false

  defp verification_running?(%{active_job: %{result_attempt_expires_at: %DateTime{} = at}}),
    do: DateTime.compare(at, DateTime.utc_now()) == :gt

  defp verification_running?(_item), do: false

  @doc "Why PtcManager could not finish this phase, in its own words."
  def phase_error(%{active_job: %{last_error: error}}) when is_binary(error) and error != "",
    do: error_sentence(error)

  def phase_error(_item), do: nil

  # The reconciliation probe records its own reason as an atom. Spell out the
  # ones a maintainer actually meets, keeping the atom so a card still matches
  # what the database and the audit trail call it, and pass anything else on.
  defp error_sentence(":no_commits"),
    do: "The agent's branch carries no commits (:no_commits)."

  defp error_sentence(":no_tree_changes"),
    do: "The agent's commits change no files (:no_tree_changes)."

  defp error_sentence(":branch_missing"),
    do: "The agent's branch does not exist (:branch_missing)."

  defp error_sentence(error), do: error

  @doc "The agent's own report of why it could not finish, when there is one."
  def stop_report(%{active_job: %{stop_report: report}}) when is_map(report), do: report
  def stop_report(_item), do: nil

  @doc "Whether this recovery is the one PtcManager offers first for that reason."
  def primary_recovery?(report, action), do: StopReport.primary_action(report) == action

  @doc "Whether this recovery may be offered at all for that reason."
  def recovery_offered?(report, action), do: StopReport.allows?(report, action)

  @doc "Every recovery offered for this report; empty means a person must read it."
  def recoveries(report), do: StopReport.recoveries(report)

  def stop_reason_label("missing_prerequisite"), do: "Missing prerequisite"
  def stop_reason_label("environment_broken"), do: "Environment broken"
  def stop_reason_label("ambiguous_requirement"), do: "Needs a decision"
  def stop_reason_label("unsafe_to_proceed"), do: "Judged unsafe"
  def stop_reason_label(_code), do: "Stopped"

  def confirming_cancel?(job_id, %{active_job: %{id: id}}), do: job_id == Integer.to_string(id)
  def confirming_cancel?(_job_id, _item), do: false

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
    started_at = item.started_at || item.publication.pr_checked_at || item.publication.inserted_at
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

  @doc """
  Returns the health of this card's agent when a person has to look at it.

  A retained agent keeps a live Herdr heartbeat while it sits at a question no
  maintainer is watching for, so the card would otherwise blame the pull request
  for standing still and every action queued against it fails a second later.
  """
  def agent_attention(%{agent_run: nil}, _now), do: nil

  def agent_attention(%{agent_run: run} = item, now) do
    if DeliveryLane.review_in_progress?(item) and run.state in ~w(blocked idle) do
      nil
    else
      case AgentHealth.assess(run, now) do
        %{status: :attention} = health -> health
        _healthy -> nil
      end
    end
  end

  def agent_attention(_item, _now), do: nil

  def repair_action(%{publication: nil}), do: nil

  def repair_action(%{publication: publication}) do
    Enum.find(ActionCatalog.pull_request_actions(publication), &(&1.key == "repair_pr"))
  end

  def repair_and_merge_action(%{publication: nil}), do: nil

  def repair_and_merge_action(%{publication: publication}) do
    Enum.find(
      ActionCatalog.pull_request_actions(publication),
      &(&1.key == "repair_and_merge_pr")
    )
  end

  def retrospective_action(%{publication: nil}), do: nil

  def retrospective_action(%{managed?: false}), do: nil

  def retrospective_action(%{publication: publication}) do
    Enum.find(ActionCatalog.pull_request_actions(publication), &(&1.key == "pr_retrospective"))
  end

  @doc """
  True when this pull request's own retrospective asked for follow-up work.

  The implementation agent adds the label when its retrospective lists untracked
  work, so the badge is GitHub's answer rather than PtcManager's guess.
  """
  def follow_up_suggested?(%{publication: %PrPublication{} = publication}),
    do: PrPublication.follow_up_suggested?(publication)

  def follow_up_suggested?(_item), do: false

  def active_agent_action?(%{state: state}) when state in ["queued", "running", "sync_pending"],
    do: true

  def active_agent_action?(_action), do: false

  def work_state(%{pr_agent_action: action}) when not is_nil(action) do
    if active_agent_action?(action), do: action.state, else: nil
  end

  def work_state(_item), do: nil

  def work_label(%{pr_agent_action: %{action_key: "repair_pr", state: "queued"}}),
    do: "Repair queued"

  def work_label(%{pr_agent_action: %{action_key: "repair_pr", state: "running"}}),
    do: "Agent repairing"

  def work_label(%{pr_agent_action: %{action_key: "repair_pr", state: "sync_pending"}}),
    do: "Checking repaired PR"

  def work_label(%{
        pr_agent_action: %{action_key: "repair_and_merge_pr", state: "queued"}
      }),
      do: "Priority merge queued"

  def work_label(%{
        pr_agent_action: %{action_key: "repair_and_merge_pr", state: "running"}
      }),
      do: "Agent fixing and merging"

  def work_label(%{
        pr_agent_action: %{action_key: "repair_and_merge_pr", state: "sync_pending"}
      }),
      do: "Waiting for confirmed merge"

  def work_label(%{pr_agent_action: %{action_key: "pr_retrospective", state: "queued"}}),
    do: "Retro queued"

  def work_label(%{pr_agent_action: %{action_key: "pr_retrospective", state: "running"}}),
    do: "Agent running retro"

  def work_label(%{
        pr_agent_action: %{action_key: "create_retrospective_issue", state: "queued"}
      }),
      do: "Follow-up queued"

  def work_label(%{
        pr_agent_action: %{action_key: "create_retrospective_issue", state: "running"}
      }),
      do: "Creating follow-up"

  def work_label(_item), do: nil

  def queue_feedback(%{
        pr_agent_action: %{action_key: "repair_and_merge_pr", state: "queued"},
        queue_blocker: %{target_label: target_label}
      }) do
    "Waiting for #{short_action_target(target_label)} to finish its fix-and-merge run. " <>
      "PtcManager starts merge work one at a time in this repository to avoid creating new conflicts."
  end

  def queue_feedback(%{
        pr_agent_action: %{action_key: "repair_and_merge_pr", state: "queued"}
      }) do
    "Safely stored in the priority merge queue. It will start when earlier repository work finishes and a Herdr slot is available."
  end

  def queue_feedback(%{pr_agent_action: %{action_key: "repair_pr", state: "queued"}}) do
    "Safely stored in the repair queue. It will start when a Herdr implementation slot is available."
  end

  def queue_feedback(%{pr_agent_action: %{state: "queued"}}) do
    "Safely stored in the agent queue. It will start when the work ahead of it finishes."
  end

  def queue_feedback(_item), do: nil

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

  def review_action_label(%{active_job: %{review_state: state}}) when state in ~w(paused manual),
    do: "Review findings and decide"

  def review_action_label(%{active_job: %{review_state: "running"}}),
    do: "View review progress"

  def review_action_label(_item), do: "View reviews"

  def next_step(%{active_job: %{review_state: state}}, _lane) when state in ~w(paused manual),
    do:
      "Review needs your decision. Open the findings to continue existing work, take over, or cancel."

  def next_step(item, lane) do
    cond do
      DeliveryLane.continuation_queued?(item) ->
        "Continuation queued; waiting for the previous agent to stop and a worker slot to become free."

      DeliveryLane.continuation_starting?(item) ->
        "A worker slot is reserved; the retained work is starting."

      DeliveryLane.review_in_progress?(item) ->
        "The review is running. No decision is needed yet; open review progress for details."

      true ->
        phase_next_step(item, lane)
    end
  end

  defp phase_next_step(_item, :queued),
    do: "PtcManager will assign this when a worker slot is free."

  defp phase_next_step(item, :working) do
    cond do
      match?(%{publication: %{draft: true}}, item) ->
        "The pull request is still a draft."

      match?(%{publication: %{checks_state: "pending"}}, item) ->
        "CI is still running."

      match?(%{publication: %{checks_state: "unknown"}}, item) ->
        "Waiting for GitHub check status."

      match?(%{publication: %{mergeability: "unknown"}}, item) ->
        "GitHub is still calculating mergeability."

      true ->
        case item.active_job.state do
          "idle" -> "The agent is idle; check whether it is waiting for input."
          "awaiting_reconciliation" -> "The agent finished; PtcManager is checking its branch."
          "verifying_result" -> "The committed branch is being verified."
          "ready_for_pr" -> "Waiting for the agent-created pull request to appear."
          "publishing_pr" -> "The verified commit is being published."
          _state -> "The assigned agent is implementing and reviewing the change."
        end
    end
  end

  defp phase_next_step(item, :stuck) do
    cond do
      work_state(item) == "queued" ->
        if item.pr_agent_action.action_key == "repair_and_merge_pr",
          do: "This priority merge is queued; no new repository work will start ahead of it.",
          else: "The repair is safely queued and will start when a Herdr slot is free."

      work_state(item) == "running" ->
        if item.pr_agent_action.action_key == "repair_and_merge_pr",
          do:
            "The repository is locked while this Herdr agent fixes, verifies, and merges the PR.",
          else: "A Herdr agent is repairing the existing pull request now."

      work_state(item) == "sync_pending" ->
        "The repair finished; PtcManager is verifying the new PR head against GitHub."

      health = agent_attention(item, DateTime.utc_now()) ->
        health.detail

      DeliveryLane.unreconciled?(item) ->
        "PtcManager checked the agent's branch and could not take it. Read the agent's " <>
          "Herdr session before discarding the worktree: a session parked at a prompt " <>
          "nobody answered leaves its work uncommitted and still reports as finished."

      match?(%{publication: %{mergeability: "conflicting"}}, item) ->
        "Merge conflicts must be resolved by the implementation agent."

      match?(%{publication: %{checks_state: "failure"}}, item) ->
        "One or more CI checks are failing."

      job_state(item) in ["failed", "lost"] ->
        "The agent stopped before completing the task."

      job_state(item) == "reconciling" ->
        "PtcManager cannot yet confirm the agent outcome."

      true ->
        "The last delivery step needs maintainer attention."
    end
  end

  defp phase_next_step(_item, :ready),
    do: "All observed gates are clean. Approve an agent to merge this pull request."

  defp load_board(socket) do
    current_runs = Operations.list_current_agent_runs()

    active_merge_actions_by_repository =
      Enum.reduce(current_runs, %{}, fn
        %{
          agent_action:
            %{
              action_key: "repair_and_merge_pr",
              repository_id: repository_id,
              state: state
            } = action
        },
        blockers
        when state in ["running", "sync_pending"] ->
          Map.put_new(blockers, repository_id, action)

        _run, blockers ->
          blockers
      end)

    active_runs_by_job =
      current_runs
      |> Enum.reject(&is_nil(&1.job_id))
      |> Map.new(&{&1.job_id, &1})

    active_runs_by_action =
      current_runs
      |> Enum.reject(&is_nil(&1.agent_action_id))
      |> Map.new(&{&1.agent_action_id, &1})

    items =
      Operations.delivery_board_items()
      |> filter_repository(socket.assigns.selected_repository)
      |> Enum.map(fn item ->
        run =
          cond do
            item.active_job -> Map.get(active_runs_by_job, item.active_job.id)
            item.pr_agent_action -> Map.get(active_runs_by_action, item.pr_agent_action.id)
            true -> nil
          end

        queue_blocker =
          case item.pr_agent_action do
            %{action_key: "repair_and_merge_pr", state: "queued", repository_id: repository_id} ->
              Map.get(active_merge_actions_by_repository, repository_id)

            _action ->
              nil
          end

        item
        |> Map.put(:agent_run, run)
        |> Map.put(:queue_blocker, queue_blocker)
      end)

    lanes =
      @lane_definitions
      |> Map.new(&{&1.key, []})
      |> Map.merge(Enum.group_by(items, &DeliveryLane.lane_for/1))

    assign(socket, lanes: lanes, item_count: length(items))
  end

  defp filter_repository(items, nil), do: items

  defp filter_repository(items, key) do
    Enum.filter(items, &(repository_key(&1.repository) == key))
  end

  defp repository_key(repository), do: "#{repository.github_owner}/#{repository.github_name}"

  defp short_action_target(target_label) when is_binary(target_label) do
    case Regex.run(~r/#(\d+)$/, target_label) do
      [_, number] -> "PR ##{number}"
      _match -> target_label
    end
  end

  def lane_title(key), do: DeliveryLane.label(key)

  defp job_state(%{active_job: %{state: state}}), do: state
  defp job_state(_item), do: nil

  def card_id(%{active_job: %{id: id}}), do: "board-job-#{id}"
  def card_id(%{publication: %{id: id}}), do: "board-pr-#{id}"

  def delivery_state(%{active_job: %{state: state}} = item) do
    cond do
      DeliveryLane.continuation_queued?(item) ->
        "queued"

      DeliveryLane.continuation_starting?(item) or DeliveryLane.review_in_progress?(item) ->
        "working"

      true ->
        state
    end
  end

  def delivery_state(_item), do: "pr_open"

  def delivery_label(%{managed?: false}), do: "External PR"

  def delivery_label(%{active_job: %{state: state}} = item) do
    cond do
      DeliveryLane.continuation_queued?(item) -> "Continuation queued"
      DeliveryLane.continuation_starting?(item) -> "Continuation starting"
      DeliveryLane.review_in_progress?(item) -> "Under review"
      true -> status_label(state)
    end
  end

  def repository_label(item), do: item.repository.github_name

  def pull_request_label(%{publication: %{pr_number: number}, issue: nil}), do: "PR ##{number}"

  def pull_request_label(%{publication: %{pr_number: number}, issue: issue}),
    do: "PR ##{number} · issue ##{issue.number}"

  def pull_request_label(%{publication: nil, issue: issue}), do: "issue ##{issue.number}"

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
