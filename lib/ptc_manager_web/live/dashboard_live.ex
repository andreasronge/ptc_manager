defmodule PtcManagerWeb.DashboardLive do
  use PtcManagerWeb, :live_view

  import PtcManagerWeb.PlanningComponents
  import PtcManagerWeb.RetrospectiveComponents, only: [retrospective: 1]

  alias PtcManager.GitHub.IssueLabels
  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Dispatch.Poller, as: DispatchPoller
  alias PtcManager.IssueDecision
  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog, as: ActionCatalog
  alias PtcManager.MaintainerActions.Poller, as: MaintainerActionPoller
  alias PtcManager.{Operations, Stalls}
  alias PtcManager.Operations.AgentHealth
  alias PtcManager.Operations.DeliveryLane
  alias PtcManager.Operations.PlanningGroup
  alias PtcManager.Repository.MaintainerLabels
  alias PtcManager.Worktrees
  alias PtcManager.Publications
  alias PtcManager.PublicationStatusPoller
  alias PtcManager.PublisherPoller
  alias PtcManager.ReviewPolicy
  alias PtcManager.ResultReconciler
  alias PtcManagerWeb.RetrospectiveComponents

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Operations.subscribe()
      Process.send_after(self(), :tick, 60_000)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:selected_repository, nil)
     |> assign(:now, DateTime.utc_now())
     |> assign(:github_syncing, false)
     |> assign(:reconciling_results, MapSet.new())
     |> assign(:collapsed_groups, MapSet.new(PlanningGroup.collapsed_by_default()))
     |> assign(:expanded_issue_ids, MapSet.new())
     |> assign(:label_writes_in_flight, MapSet.new())
     |> load_dashboard()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_repository, selected_repository(params, Operations.list_repositories()))
     |> load_dashboard()}
  end

  @impl true
  def handle_event("sync-github", _params, %{assigns: %{github_syncing: false}} = socket) do
    {:noreply,
     socket
     |> assign(:github_syncing, true)
     |> start_async(:github_sync, &GitHubSync.sync_enabled_repositories/0)}
  end

  def handle_event("sync-github", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-group", %{"group" => group}, socket) do
    # The name arrives from the browser, so it is matched against the groups
    # this page actually has rather than turned into an atom.
    case Enum.find(PlanningGroup.order(), &(Atom.to_string(&1) == group)) do
      nil ->
        {:noreply, socket}

      group ->
        {:noreply,
         update(socket, :collapsed_groups, fn collapsed ->
           if MapSet.member?(collapsed, group),
             do: MapSet.delete(collapsed, group),
             else: MapSet.put(collapsed, group)
         end)}
    end
  end

  def handle_event("toggle-issue", %{"issue-id" => issue_id}, socket) do
    case parse_issue_id(issue_id) do
      {:ok, issue_id} ->
        {:noreply,
         update(socket, :expanded_issue_ids, fn expanded ->
           if MapSet.member?(expanded, issue_id),
             do: MapSet.delete(expanded, issue_id),
             else: MapSet.put(expanded, issue_id)
         end)}

      {:error, :invalid_issue_id} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("start-collection-run", %{"issue-id" => issue_id} = params, socket) do
    case parse_issue_id(issue_id) do
      {:ok, id} ->
        id
        |> PtcManager.Collections.start(
          %{
            auto_merge: params["auto-merge"] == "true",
            auto_recover: params["auto-recover"] == "true"
          },
          socket.assigns.actor
        )
        |> collection_run_result(socket, "Collection run started.")

      {:error, _invalid} ->
        {:noreply, socket}
    end
  end

  def handle_event("collection-run", %{"run-id" => run_id, "decision" => decision}, socket)
      when decision in ["pause", "resume", "accept", "cancel"] do
    case Integer.parse(run_id) do
      {id, ""} ->
        {outcome, message} =
          case decision do
            "pause" ->
              {PtcManager.Collections.pause(id, socket.assigns.actor), "Collection run paused."}

            "resume" ->
              {PtcManager.Collections.resume(id, socket.assigns.actor), "Collection run resumed."}

            "accept" ->
              {PtcManager.Collections.accept_changes(id, socket.assigns.actor),
               "Membership accepted."}

            "cancel" ->
              {PtcManager.Collections.cancel(id, socket.assigns.actor),
               "Collection run cancelled."}
          end

        collection_run_result(outcome, socket, message)

      _invalid ->
        {:noreply, socket}
    end
  end

  # One form, two submit buttons: "Fix directly" is the same decision made
  # without a preparation round, so it deliberately carries the same review
  # count the maintainer picked next to it.
  def handle_event("approve", %{"issue-id" => issue_id} = params, socket) do
    with {:ok, issue_id} <- parse_issue_id(issue_id),
         {:ok, review_count} <- parse_review_count(params["review-count"]) do
      if params["direct"] == "true",
        do: approve_directly(issue_id, review_count, params["execution-profile"], socket),
        else: approve_issue(issue_id, review_count, params["execution-profile"], socket)
    else
      {:error, :invalid_issue_id} ->
        {:noreply, put_flash(socket, :error, "That issue could not be found.")}

      {:error, :invalid_review_count} ->
        {:noreply, put_flash(socket, :error, "Choose between zero and five reviews.")}
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
       |> load_dashboard()}
    else
      {:error, :agent_action_already_active} ->
        {:noreply, put_flash(socket, :error, "That action is already queued or running.")}

      {:error, :pull_request_not_finished} ->
        {:noreply, put_flash(socket, :error, "The pull request must be finished first.")}

      {:error, :issue_closed} ->
        {:noreply, put_flash(socket, :error, "The issue has already been closed.")}

      _error ->
        {:noreply, put_flash(socket, :error, "The agent action could not be queued.")}
    end
  end

  def handle_event(
        "resolve-issue-decision",
        %{
          "issue-id" => issue_id,
          "source-action-id" => source_action_id,
          "decision" => decision
        },
        socket
      ) do
    choice = Map.get(decision, "choice", "")
    custom_answer = Map.get(decision, "custom_answer", "")

    with {issue_id, ""} <- Integer.parse(issue_id),
         {source_action_id, ""} <- Integer.parse(source_action_id),
         {:ok, _action} <-
           MaintainerActions.enqueue_issue_decision(
             issue_id,
             source_action_id,
             choice,
             custom_answer,
             socket.assigns.actor
           ) do
      MaintainerActionPoller.wake()

      {:noreply,
       socket
       |> put_flash(:info, "Your decision is queued for the agent to apply to GitHub.")
       |> load_dashboard()}
    else
      {:error, :decision_answer_missing} ->
        {:noreply, put_flash(socket, :error, "Choose an option or write your own answer.")}

      {:error, :decision_answer_too_long} ->
        {:noreply, put_flash(socket, :error, "Keep the custom answer under 2,000 characters.")}

      {:error, :agent_action_already_active} ->
        {:noreply, put_flash(socket, :error, "An agent action is already queued or running.")}

      {:error, :issue_decision_not_current} ->
        {:noreply,
         put_flash(socket, :error, "GitHub no longer reports this decision as unresolved.")}

      _error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The decision could not be queued. Synchronize GitHub and try again."
         )}
    end
  end

  def handle_event("toggle-issue-label", %{"issue-id" => issue_id, "name" => name}, socket) do
    with {:ok, issue_id} <- parse_issue_id(issue_id),
         false <- MapSet.member?(socket.assigns.label_writes_in_flight, {issue_id, name}),
         %{repository: %{}} = issue <- Operations.get_issue(issue_id) do
      actor = socket.assigns.actor

      {:noreply,
       socket
       |> update(:label_writes_in_flight, &MapSet.put(&1, {issue_id, name}))
       |> start_async({:issue_label, issue_id, name}, fn ->
         IssueLabels.toggle(issue.repository, issue, name, actor)
       end)}
    else
      # A stale card, a second click, or an id the browser made up.
      _unavailable -> {:noreply, socket}
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

    {:noreply, socket |> put_flash(kind, message) |> load_dashboard()}
  end

  def handle_event("dismiss-follow-up", %{"publication-id" => publication_id}, socket) do
    with {publication_id, ""} <- Integer.parse(publication_id),
         {:ok, _publication} <-
           Publications.dismiss_follow_up(publication_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Dismissed. The pull request and its labels are unchanged.")
       |> load_dashboard()}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "That suggestion could not be dismissed.")
         |> load_dashboard()}
    end
  end

  def handle_event("discard-worktree", %{"allocation-id" => allocation_id}, socket) do
    with {allocation_id, ""} <- Integer.parse(allocation_id),
         :ok <- Worktrees.discard_attention(allocation_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Worktree discarded.")
       |> load_dashboard()}
    else
      {:error, :worktree_in_use} ->
        {:noreply, put_flash(socket, :error, "That worktree still belongs to an active agent.")}

      {:error, :worktree_not_retained} ->
        {:noreply, put_flash(socket, :error, "That worktree is no longer waiting for attention.")}

      {:error, {:worktree_cleanup_failed, reason}} ->
        {:noreply,
         put_flash(socket, :error, "The worktree could not be removed: #{inspect(reason)}")}

      _error ->
        {:noreply, put_flash(socket, :error, "That worktree could not be discarded.")}
    end
  end

  def handle_event("reconcile-result", %{"job-id" => job_id}, socket) do
    with {job_id, ""} <- Integer.parse(job_id),
         false <- MapSet.member?(socket.assigns.reconciling_results, job_id) do
      {:noreply,
       socket
       |> update(:reconciling_results, &MapSet.put(&1, job_id))
       |> start_async({:reconcile_result, job_id}, fn -> ResultReconciler.run_job(job_id) end)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("retry-publication", %{"publication-id" => publication_id}, socket) do
    with {publication_id, ""} <- Integer.parse(publication_id),
         {:ok, _publication} <-
           Publications.retry_blocked(publication_id, socket.assigns.actor) do
      PublisherPoller.wake()
      PublicationStatusPoller.wake()

      {:noreply,
       socket
       |> put_flash(:info, "PR publication is queued again.")
       |> load_dashboard()}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Publication could not be retried safely.")}
    end
  end

  defp collection_run_result(outcome, socket, message) do
    case outcome do
      {:ok, _run} ->
        {:noreply, socket |> put_flash(:info, message) |> load_dashboard()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, collection_run_error(reason))}
    end
  end

  defp collection_run_error(:not_a_collection), do: "This issue has no sub-issues."
  defp collection_run_error(:run_already_live), do: "This collection already has a run."
  defp collection_run_error(:issue_closed), do: "This issue is closed."
  defp collection_run_error(:repository_disabled), do: "Enable the repository first."
  defp collection_run_error(:run_not_paused), do: "This run is not paused."
  defp collection_run_error(:run_not_live), do: "This run has already ended."

  defp collection_run_error(:accept_changes_required),
    do: "GitHub's sub-issues changed. Accept the new membership instead of resuming."

  defp collection_run_error({:member_in_flight, number}),
    do: "##{number} is being worked on and cannot be dropped from the run."

  defp collection_run_error({:structure_invalid, {:member_without_workflow_label, number}}),
    do: "##{number} needs exactly one ptc: workflow label first."

  defp collection_run_error({:structure_invalid, {:member_not_synchronized, number}}),
    do: "##{number} has not been synchronized yet. Sync GitHub first."

  defp collection_run_error({:structure_invalid, {:foreign_blocker, number, blocker}}),
    do: "##{number} is blocked by ##{blocker}, which is not a member."

  defp collection_run_error({:structure_invalid, {:dependency_cycle, number}}),
    do: "The members form a dependency cycle through ##{number}."

  defp collection_run_error({:structure_invalid, reason}),
    do: "The collection is not well formed: #{inspect(reason)}."

  defp collection_run_error(:deployment_draining),
    do: "A deployment is draining; try again shortly."

  defp collection_run_error(:maintenance_mode), do: "PtcManager is in maintenance mode."

  defp collection_run_error(reason),
    do: "The collection run could not be changed: #{inspect(reason)}"

  defp approve_directly(issue_id, review_count, profile, socket) do
    issue_id
    |> Operations.approve_issue_directly(socket.assigns.actor, review_count, profile)
    |> approval_result(review_count, socket, "Started directly, without a preparation round.")
  end

  defp approve_issue(issue_id, review_count, profile, socket) do
    issue_id
    |> Operations.approve_issue(socket.assigns.actor, review_count, profile)
    |> approval_result(review_count, socket, "Approved.")
  end

  defp approval_result(outcome, _review_count, socket, prefix) do
    case outcome do
      {:ok, job} ->
        DispatchPoller.wake()
        review_count = job.required_review_count

        review_message =
          "Maximum #{review_count} review #{if(review_count == 1, do: "round", else: "rounds")} · #{job.execution_settings["name"]} / #{job.execution_settings["model"]}"

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{prefix} #{review_message}. One implementation job is now queued."
         )
         |> load_dashboard()}

      {:error, :already_active} ->
        {:noreply, put_flash(socket, :error, "This issue already has active work.")}

      {:error, :stale_proposal} ->
        {:noreply, put_flash(socket, :error, "The issue changed. Investigate it again first.")}

      {:error, :issue_closed} ->
        {:noreply, put_flash(socket, :error, "This issue is closed and cannot be started.")}

      {:error, :issue_claimed} ->
        {:noreply, put_flash(socket, :error, "This issue is already assigned on GitHub.")}

      {:error, :issue_claim_unknown} ->
        {:noreply, put_flash(socket, :error, "Synchronize GitHub assignment state first.")}

      {:error, :proposal_not_ready} ->
        {:noreply, put_flash(socket, :error, "This issue is not ready to start.")}

      {:error, :issue_workflow_not_ready} ->
        {:noreply, put_flash(socket, :error, "GitHub does not mark this issue ready.")}

      {:error, :issue_dependencies_unresolved} ->
        {:noreply, put_flash(socket, :error, "This issue still has an unresolved dependency.")}

      {:error, :invalid_review_count} ->
        {:noreply, put_flash(socket, :error, "Choose between zero and five reviews.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approval failed: #{inspect(reason)}")}
    end
  end

  defp label_error(:label_writes_disabled),
    do: "This host cannot write GitHub labels; no worker wrapper is installed."

  defp label_error(:label_not_configured),
    do: "That label is not configured for this repository any more."

  defp label_error(:reserved_label_name),
    do: "The ptc: labels are a read-only projection of GitHub."

  defp label_error(:issue_closed), do: "This issue is closed."
  defp label_error(:label_wrapper_timeout), do: "GitHub did not answer within 30 seconds."

  defp label_error({:label_wrapper_exit, status}),
    do: "The GitHub label change failed with status #{status}. Check that the label exists."

  defp label_error(_reason), do: "The label could not be changed on GitHub."

  defp parse_review_count(value) when value in [nil, ""], do: {:ok, nil}

  defp parse_review_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count in 0..5 -> {:ok, count}
      _ -> {:error, :invalid_review_count}
    end
  end

  defp parse_issue_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {issue_id, ""} -> {:ok, issue_id}
      _ -> {:error, :invalid_issue_id}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 60_000)
    now = DateTime.utc_now()

    {:noreply, socket |> assign(:now, now) |> assign_stalls(now, socket.assigns.repositories)}
  end

  # A Herdr sync broadcasts every few seconds; the stalls it could change are
  # time-based and the minute tick recomputes them. Every other change is a
  # mutation a person or a worker made, which may have answered a stall.
  def handle_info({:operations_changed, PtcManager.Herdr.Sync}, socket),
    do: {:noreply, load_dashboard(socket, stalls: false)}

  def handle_info({:operations_changed, _source}, socket),
    do: {:noreply, load_dashboard(socket)}

  @impl true
  def handle_async(:github_sync, {:ok, results}, socket) do
    successful? = results != [] and Enum.all?(results, &match?({:ok, _summary}, &1))

    socket =
      socket
      |> assign(:github_syncing, false)
      |> load_dashboard()

    if successful? do
      {:noreply, put_flash(socket, :info, "GitHub issues synchronized read-only.")}
    else
      {:noreply, put_flash(socket, :error, "GitHub synchronization did not complete.")}
    end
  end

  def handle_async(:github_sync, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:github_syncing, false)
     |> put_flash(:error, "GitHub synchronization stopped unexpectedly.")
     |> load_dashboard()}
  end

  def handle_async({:issue_label, issue_id, name}, {:ok, result}, socket) do
    socket =
      socket
      |> update(:label_writes_in_flight, &MapSet.delete(&1, {issue_id, name}))
      |> load_dashboard()

    case result do
      {:ok, :added} ->
        {:noreply, put_flash(socket, :info, "Added #{name} on GitHub.")}

      {:ok, :removed} ->
        {:noreply, put_flash(socket, :info, "Removed #{name} on GitHub.")}

      {:ok, operation, {:sync_failed, _reason}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "GitHub #{operation} #{name}, but PtcManager could not read the issue back. Synchronize GitHub."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, label_error(reason))}
    end
  end

  def handle_async({:issue_label, issue_id, name}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:label_writes_in_flight, &MapSet.delete(&1, {issue_id, name}))
     |> put_flash(:error, "The label change stopped unexpectedly. Synchronize GitHub to check.")
     |> load_dashboard()}
  end

  def handle_async({:reconcile_result, job_id}, {:ok, result}, socket) do
    socket =
      socket
      |> update(:reconciling_results, &MapSet.delete(&1, job_id))
      |> load_dashboard()

    case result do
      {:ok, _job} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Committed branch verified. Waiting for publication."
         )}

      {:error, :result_already_claimed} ->
        {:noreply, put_flash(socket, :info, "This branch is already being checked.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The committed branch is not ready yet."
         )}
    end
  end

  def handle_async({:reconcile_result, job_id}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:reconciling_results, &MapSet.delete(&1, job_id))
     |> put_flash(:error, "Branch verification stopped unexpectedly.")
     |> load_dashboard()}
  end

  def elapsed(now, started_at), do: TimeFormat.elapsed(now, started_at)

  defdelegate fresh?(item), to: PlanningGroup
  defdelegate approvable?(item), to: PlanningGroup
  defdelegate startable?(item), to: PlanningGroup
  defdelegate dependencies_need_decision?(dependencies), to: PlanningGroup

  def collapsed_group?(collapsed, group), do: MapSet.member?(collapsed, group)
  def writing_label?(in_flight, issue, name), do: MapSet.member?(in_flight, {issue.id, name})

  def maintainer_label_chips(issue) do
    Enum.map(
      MaintainerLabels.list(issue.repository),
      &{&1["name"], MaintainerLabels.reported?(issue, &1["name"])}
    )
  end

  def expanded_issue?(expanded, item), do: MapSet.member?(expanded, item.issue.id)

  @doc "The Delivery board lane an already-delivered issue currently sits in."
  def delivery_lane(item) do
    DeliveryLane.lane_for(%{
      active_job: item.active_job,
      publication: item.publication || item.external_publication
    })
  end

  @doc "The one button a collapsed card offers for issues that are not ready."
  def primary_issue_action(item, :needs_decision) do
    actions = ActionCatalog.issue_actions(item.issue)
    Enum.find(actions, &(&1.key == "review_issue")) || List.first(actions)
  end

  def primary_issue_action(item, group) when group in [:not_prepared, :stale, :blocked, :waiting],
    do: List.first(ActionCatalog.issue_actions(item.issue))

  def primary_issue_action(item, :collections) do
    actions = ActionCatalog.issue_actions(item.issue)
    Enum.find(actions, &(&1.key == "structure_collection"))
  end

  def primary_issue_action(_item, _group), do: nil

  @doc "The live collection run of an item, or nil."
  def collection_run(item), do: Map.get(item, :collection_run)

  @doc "One line saying where a collection run stands."
  def collection_run_label(%{state: "active"}), do: "Running unattended"

  def collection_run_label(%{state: "finishing"}),
    do: "Delivered · waiting for the umbrella to close"

  def collection_run_label(%{state: "paused", pause_kind: "membership_changed"}),
    do: "Paused · GitHub's sub-issues changed"

  def collection_run_label(%{state: "paused", paused_issue_number: number})
      when is_integer(number),
      do: "Paused on ##{number}"

  def collection_run_label(%{state: "paused"}), do: "Paused"
  def collection_run_label(_run), do: nil

  @doc "Which run buttons a card offers."
  def collection_run_buttons(%{state: "active"}), do: [:pause, :cancel]
  def collection_run_buttons(%{state: "finishing"}), do: [:cancel]

  def collection_run_buttons(%{state: "paused", pause_kind: "membership_changed"}),
    do: [:accept, :cancel]

  def collection_run_buttons(%{state: "paused"}), do: [:resume, :cancel]
  def collection_run_buttons(_run), do: []

  def collection_run_button_label(:pause), do: "Pause"
  def collection_run_button_label(:resume), do: "Resume"
  def collection_run_button_label(:accept), do: "Accept changes"
  def collection_run_button_label(:cancel), do: "Cancel run"

  @doc "The actions the expanded card still has to offer after the primary one."
  def secondary_issue_actions(item, group) do
    case primary_issue_action(item, group) do
      nil -> ActionCatalog.issue_actions(item.issue)
      primary -> Enum.reject(ActionCatalog.issue_actions(item.issue), &(&1.key == primary.key))
    end
  end

  @doc """
  Groups whose cards still offer the approve form.

  A blocked, parked, or already-delivered issue does not: its group already says
  why it cannot start. An unprepared one does, disabled, because the maintainer
  is looking at it precisely to find out what is missing.
  """
  def approval_group?(group), do: group in [:ready, :not_prepared]

  def active_agent_action?(%{state: state}) when state in ["queued", "running", "sync_pending"],
    do: true

  def active_agent_action?(_action), do: false
  def agent_action_label(%{action_key: "repair_pr", state: "queued"}), do: "Repair queued"
  def agent_action_label(%{action_key: "repair_pr", state: "running"}), do: "Agent repairing"

  def agent_action_label(%{action_key: "repair_pr", state: "sync_pending"}),
    do: "Checking repaired PR"

  def agent_action_label(%{state: "queued"}), do: "Agent action queued"
  def agent_action_label(%{state: "running"}), do: "Agent action running"
  def agent_action_label(%{state: "sync_pending"}), do: "Waiting for GitHub sync"
  def agent_action_label(%{state: "done"}), do: "Last agent action completed"
  def agent_action_label(%{state: "failed"}), do: "Last agent action failed"
  def agent_action_label(_action), do: nil

  def agent_action_private_summary(action) do
    action |> decode_agent_action_result() |> Map.get("private_summary")
  end

  def agent_action_outcome(action) do
    action |> decode_agent_action_result() |> Map.get("outcome")
  end

  def agent_action_result_items(action, key) do
    case Map.get(decode_agent_action_result(action), key) do
      items when is_list(items) -> items
      _items -> []
    end
  end

  def agent_action_source_note(%{target_snapshot: snapshot}) when is_map(snapshot) do
    case snapshot do
      %{"source_sha" => source_sha, "source_ref" => source_ref}
      when is_binary(source_sha) and is_binary(source_ref) ->
        "Code evidence: #{source_ref} @ #{String.slice(source_sha, 0, 10)}"

      _snapshot ->
        nil
    end
  end

  def agent_action_source_note(_action), do: nil

  def issue_decision(
        %{workflow_label: "ptc:needs-decision", content_digest: content_digest},
        %{state: "done", target_snapshot: snapshot} = action
      ) do
    if is_map(snapshot) and snapshot["decision_issue_content_digest"] == content_digest do
      case action |> decode_agent_action_result() |> IssueDecision.from_result() do
        {:ok, decision} -> decision
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  def issue_decision(_issue, _action), do: nil

  def decision_refresh_reason(
        %{workflow_label: "ptc:needs-decision", content_digest: content_digest},
        %{state: "done", target_snapshot: snapshot} = action
      ) do
    case action |> decode_agent_action_result() |> IssueDecision.from_result() do
      {:error, _reason} ->
        :choices_unavailable

      {:ok, _decision} ->
        if is_map(snapshot) and snapshot["decision_issue_content_digest"] == content_digest,
          do: nil,
          else: :issue_changed
    end
  end

  def decision_refresh_reason(_issue, _action), do: nil

  def agent_action_failure(%{state: "failed", last_error: error}) when is_binary(error) do
    cond do
      String.contains?(error, ["invalid_json_schema", "invalid_output_schema"]) ->
        "Codex rejected the configured result format. Run the action again; if it repeats, the Codex configuration needs attention."

      String.contains?(error, "codex_exit") ->
        "Codex stopped before producing a usable result. Run the action again."

      true ->
        error
    end
  end

  def agent_action_failure(_action), do: nil

  def reconciling_result?(jobs, job_id), do: MapSet.member?(jobs, job_id)
  def job_label("ready_for_pr"), do: "waiting for PR publication"
  def job_label("pr_open"), do: "PR open"
  def job_label(state), do: state |> String.replace("_", " ")

  def short_time(datetime), do: TimeFormat.utc(datetime)

  def publication_error(nil), do: "PR verification needs attention."

  def publication_error(error) do
    cond do
      String.contains?(error, "github_app_not_configured") ->
        "The GitHub App publication broker is not configured."

      String.contains?(error, "remote_branch_diverged") ->
        "The remote job branch contains a different commit."

      String.contains?(error, "pull_request_already_closed") ->
        "A pull request for this job branch was already closed."

      String.contains?(error, "authoritative_diff_changed") ->
        "The GitHub-base diff no longer matches the verified result."

      true ->
        "The last PR verification failed safely; details are in the audit log."
    end
  end

  def worker_capacity(worker) do
    case worker.capabilities["implementation_slots"] do
      value when is_integer(value) and value > 0 ->
        value

      _value ->
        if worker.capabilities["herdr"],
          do: Application.get_env(:ptc_manager, :heavy_agent_capacity, 1),
          else: 0
    end
  end

  def active_worktrees(worker),
    do:
      Enum.count(
        worker.worktree_allocations,
        &Operations.worktree_consumes_execution_slot?/1
      )

  def retained_worktrees(worker),
    do: Enum.count(worker.worktree_allocations, &(&1.state == "waiting"))

  def worktree_state_label(state), do: state |> String.replace("_", " ")

  def discardable_worktree?(%{state: "attention"} = allocation),
    do:
      not PtcManager.Reviews.held?(allocation.job) and
        not Operations.worktree_consumes_execution_slot?(allocation)

  def discardable_worktree?(_allocation), do: false

  def required_reviews(repository), do: ReviewPolicy.default_count(repository)

  def job_review_label(job, repository) do
    count = ReviewPolicy.job_count(job, repository)

    if job.execution_settings,
      do: "Up to #{count} review #{if(count == 1, do: "round", else: "rounds")}",
      else: "#{count} review #{if(count == 1, do: "pass", else: "passes")}"
  end

  def agent_publication?(%{publication: %{source: "agent"}}), do: true
  def agent_publication?(%{active_job: %{publication_source: "agent"}}), do: true
  def agent_publication?(_item), do: false

  def agent_name(run) do
    case run.agent_name do
      name when is_binary(name) and name != "" -> name
      _name -> "Agent"
    end
  end

  def dependency_status(%{lookup_state: state}) when state != "resolved", do: "unknown"

  def dependency_status(%{state: "closed", state_reason: "completed"}), do: "completed"
  def dependency_status(%{state: "closed"}), do: "closed without completion"

  def dependency_status(%{active_job: %{state: state}}),
    do: job_label(state)

  def dependency_status(%{state: "open"}), do: "open"

  def dependency_status(%{issue: %{state: "closed", github_state_reason: "completed"}}),
    do: "completed"

  def dependency_status(%{issue: %{state: "closed"}}), do: "closed without completion"

  def dependency_status(%{issue: %{state: "open"}}), do: "open"
  def dependency_status(_dependency), do: "unknown"

  def dependencies_resolved?(dependencies) do
    dependencies != [] and Enum.all?(dependencies, &dependency_completed?/1)
  end

  def dependency_url(_repository, %{html_url: html_url}) when is_binary(html_url), do: html_url
  def dependency_url(_repository, %{issue: %{html_url: html_url}}), do: html_url

  def dependency_url(_repository, %{repository_full_name: full_name, number: number}) do
    "https://github.com/#{full_name}/issues/#{number}"
  end

  def dependency_dom_id(issue_id, dependency) do
    repository = String.replace(dependency.repository_full_name, ~r/[^a-zA-Z0-9_-]/, "-")
    "issue-#{issue_id}-blocked-by-#{repository}-#{dependency.number}"
  end

  def dependency_cycle_label(cycle) do
    Enum.map_join(cycle, " → ", fn {repository, number} -> "#{repository}##{number}" end)
  end

  def dependencies_unknown?(dependencies) do
    Enum.any?(
      dependencies,
      &(&1.lookup_state != "resolved" or dependency_status(&1) == "unknown")
    )
  end

  defp dependency_completed?(%{lookup_state: "resolved", state: "closed", state_reason: reason}),
    do: reason == "completed"

  defp dependency_completed?(_dependency), do: false

  defp load_dashboard(socket, opts \\ []) do
    repositories = Operations.list_repositories()
    selected_repository = socket.assigns.selected_repository

    issues =
      Operations.dashboard_issues(state: "open")
      |> filter_repository(selected_repository, & &1.issue.repository)

    follow_ups =
      Operations.follow_up_items()
      |> filter_repository(selected_repository, & &1.repository)

    socket
    |> then(fn socket ->
      if Keyword.get(opts, :stalls, true),
        do: assign_stalls(socket, socket.assigns.now, repositories),
        else: socket
    end)
    |> assign(
      repositories: repositories,
      execution_profiles: PtcManager.ExecutionProfiles.list(),
      issues: issues,
      grouped_issues: group_issues(issues, follow_ups, socket.assigns.now),
      active_agent_runs:
        Operations.list_active_agent_runs()
        |> filter_repository(selected_repository, &agent_run_repository/1),
      waiting_agent_runs:
        Operations.list_waiting_agent_runs()
        |> filter_repository(selected_repository, &agent_run_repository/1),
      recent_agent_runs: recent_agent_runs(repositories, selected_repository),
      workers: Operations.list_workers_with_worktrees(),
      publication_enabled: Application.get_env(:ptc_manager, :publication_enabled, false)
    )
  end

  # Stalls carry a repository id rather than a struct, so the repository filter
  # resolves it against the repositories the page already lists.
  defp assign_stalls(socket, now, repositories) do
    stalls =
      Stalls.detect(now)
      |> filter_repository(socket.assigns.selected_repository, fn stall ->
        Enum.find(repositories, &(&1.id == stall.repository_id))
      end)

    assign(socket, :stalls, stalls)
  end

  @doc false
  def stall_path(
        %{target_type: "collection_run", repository_id: id, issue_id: issue_id},
        repositories
      ) do
    case Enum.find(repositories, &(&1.id == id)) do
      nil -> ~p"/"
      repository -> "/?repo=#{repository_key(repository)}#issue-#{issue_id}"
    end
  end

  # A cancelled job has no board card, and a failed issue action is rerun from
  # the issue's card: both answers are on Planning.
  def stall_path(%{kind: kind, issue_id: issue_id} = stall, repositories)
      when kind in [:dispatch_rejected, :action_repeating_failure] and is_integer(issue_id),
      do: stall_path(%{stall | target_type: "collection_run"}, repositories)

  def stall_path(%{kind: kind, target_id: job_id}, _repositories)
      when kind in [:review_snoozing, :review_repeated_finding],
      do: ~p"/jobs/#{job_id}/reviews"

  def stall_path(%{target_type: type}, _repositories)
      when type in ["job", "pr_publication", "agent_action"],
      do: ~p"/board"

  def stall_path(%{target_type: "operational_mode"}, _repositories), do: ~p"/deployments"

  def stall_path(_stall, _repositories), do: ~p"/operations"

  defp group_issues(issues, follow_ups, now) do
    grouped =
      issues
      |> Enum.group_by(
        &PlanningGroup.classify(&1,
          now: now,
          parked_labels: MaintainerLabels.parked_names(&1.issue.repository)
        )
      )
      |> Map.put(:follow_ups, follow_ups)

    for group <- PlanningGroup.order(),
        items = Map.get(grouped, group, []),
        items != [],
        do: {group, items}
  end

  defp selected_repository(%{"repo" => key}, repositories) do
    if Enum.any?(repositories, &(repository_key(&1) == key)), do: key, else: nil
  end

  defp selected_repository(_params, _repositories), do: nil

  defp filter_repository(items, nil, _repository), do: items

  defp filter_repository(items, key, repository) do
    Enum.filter(items, fn item ->
      case repository.(item) do
        nil -> false
        item_repository -> repository_key(item_repository) == key
      end
    end)
  end

  defp repository_key(repository), do: "#{repository.github_owner}/#{repository.github_name}"

  defp recent_agent_runs(_repositories, nil), do: Operations.list_recent_agent_runs()

  defp recent_agent_runs(repositories, key) do
    repository = Enum.find(repositories, &(repository_key(&1) == key))
    Operations.list_recent_agent_runs_for_repository(repository.id)
  end

  defp agent_run_repository(%{job: %{repository: repository}}), do: repository

  defp agent_run_repository(%{agent_action: %{repository: repository}}), do: repository

  defp agent_run_repository(_run), do: nil

  defp decode_agent_action_result(%{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> result
      _result -> %{}
    end
  end

  defp decode_agent_action_result(_action), do: %{}
end
