defmodule PtcManagerWeb.DeliveryBoardLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog, as: ActionCatalog
  alias PtcManager.MaintainerActions.Poller, as: MaintainerActionPoller
  alias PtcManager.Operations
  alias PtcManager.Operations.AgentHealth

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
      key: :stuck,
      title: "Needs attention",
      subtitle: "Failure, conflict, or decision",
      color: "bg-amber-400"
    },
    %{
      key: :ready,
      title: "Ready to merge",
      subtitle: "Clean checks and no conflicts",
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
     |> assign(:selected_repository, nil)
     |> assign(:repositories, Operations.list_repositories())
     |> assign(:now, DateTime.utc_now())
     |> assign(:lane_definitions, @lane_definitions)
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
    with {source_action_id, ""} <- Integer.parse(source_action_id),
         {suggestion_index, ""} <- Integer.parse(suggestion_index),
         {:ok, _action} <-
           MaintainerActions.enqueue_retrospective_issue(
             source_action_id,
             suggestion_index,
             socket.assigns.actor
           ) do
      MaintainerActionPoller.wake()

      {:noreply,
       socket
       |> put_flash(:info, "Approved follow-up queued for GitHub issue creation.")
       |> load_board()}
    else
      {:error, :suggestion_already_handled} ->
        {:noreply, put_flash(socket, :info, "That follow-up is already queued or handled.")}

      {:error, :agent_action_already_active} ->
        {:noreply, put_flash(socket, :error, "Another PR action is already queued or running.")}

      _error ->
        {:noreply, put_flash(socket, :error, "The follow-up issue could not be queued.")}
    end
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

  def agent_attention(%{agent_run: run}, now) do
    case AgentHealth.assess(run, now) do
      %{status: :attention} = health -> health
      _healthy -> nil
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

  def retrospective_suggestions(%{state: "done", result_summary: body})
      when is_binary(body) do
    with {:ok, result} <- Jason.decode(body),
         suggestions when is_list(suggestions) <- result["suggestions"] do
      Enum.with_index(suggestions)
    else
      _result -> []
    end
  end

  def retrospective_suggestions(_action), do: []

  def retrospective_summary(%{state: "done", result_summary: body}) when is_binary(body) do
    with {:ok, result} <- Jason.decode(body),
         summary when is_binary(summary) <- result["private_summary"] do
      summary
    else
      _result -> nil
    end
  end

  def retrospective_summary(_action), do: nil

  def suggestion_action(item, source_action_id, suggestion_index) do
    Enum.find(item.pr_retrospective_issue_actions, fn action ->
      action.target_snapshot["source_action_id"] == source_action_id and
        action.target_snapshot["suggestion_index"] == suggestion_index
    end)
  end

  def suggestion_action_active?(%{state: state})
      when state in ["queued", "running", "sync_pending"],
      do: true

  def suggestion_action_active?(_action), do: false

  def suggestion_action_label(%{state: "queued"}), do: "Issue queued"
  def suggestion_action_label(%{state: "running"}), do: "Creating issue"
  def suggestion_action_label(%{state: "sync_pending"}), do: "Checking GitHub"
  def suggestion_action_label(%{state: "failed"}), do: "Try again"
  def suggestion_action_label(_action), do: "Add as GitHub issue"

  def created_issue_number(%{state: "done", result_summary: body}) when is_binary(body) do
    with {:ok, result} <- Jason.decode(body),
         [number] <- result["created_issue_numbers"],
         true <- is_integer(number) do
      number
    else
      _result -> nil
    end
  end

  def created_issue_number(_action), do: nil

  def suggestion_not_created?(%{state: "done", result_summary: body}) when is_binary(body) do
    with {:ok, result} <- Jason.decode(body) do
      result["outcome"] == "no-followups"
    else
      _result -> false
    end
  end

  def suggestion_not_created?(_action), do: false

  def issue_url(item, issue_number) do
    "https://github.com/#{item.issue.repository.github_owner}/#{item.issue.repository.github_name}/issues/#{issue_number}"
  end

  def category_label(category) when is_binary(category) do
    category |> String.replace("-", " ") |> String.capitalize()
  end

  def category_label(_category), do: "Follow-up"

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

  def next_step(item, :stuck) do
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

  def next_step(_item, :ready),
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
      |> Map.merge(Enum.group_by(items, &lane_for/1))

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

  defp lane_for(item) do
    cond do
      job_state(item) == "queued" -> :queued
      stuck?(item) -> :stuck
      ready?(item) -> :ready
      true -> :working
    end
  end

  defp stuck?(item) do
    job_state(item) in ["blocked", "reconciling", "publish_blocked", "failed", "lost"] or
      match?(%{checks_state: "failure"}, item.publication) or
      match?(%{mergeability: "conflicting"}, item.publication) or
      match?(
        %{draft: false, checks_state: checks_state, mergeability: "blocked"}
        when checks_state in ["success", "none"],
        item.publication
      )
  end

  defp ready?(item) do
    open_pull_request?(item) and
      match?(%{state: "published", pr_state: "open", draft: false}, item.publication) and
      item.publication.checks_state in ["success", "none"] and
      item.publication.mergeability == "mergeable"
  end

  defp open_pull_request?(%{publication: %{state: "published", pr_state: "open"}}), do: true
  defp open_pull_request?(_item), do: false

  defp job_state(%{active_job: %{state: state}}), do: state
  defp job_state(_item), do: nil

  def card_id(%{active_job: %{id: id}}), do: "board-job-#{id}"
  def card_id(%{publication: %{id: id}}), do: "board-pr-#{id}"

  def delivery_state(%{active_job: %{state: state}}), do: state
  def delivery_state(_item), do: "pr_open"

  def delivery_label(%{managed?: false}), do: "External PR"
  def delivery_label(%{active_job: %{state: state}}), do: status_label(state)

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
