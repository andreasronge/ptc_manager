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
  alias PtcManager.Operations
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
  # One form, two submit buttons: "Fix directly" is the same decision made
  # without a preparation round, so it deliberately carries the same review
  # count the maintainer picked next to it.
  def handle_event("approve", %{"issue-id" => issue_id} = params, socket) do
    with {:ok, issue_id} <- parse_issue_id(issue_id),
         {:ok, review_count} <- parse_review_count(params["review-count"]) do
      if params["direct"] == "true",
        do: approve_directly(issue_id, review_count, socket),
        else: approve_issue(issue_id, review_count, socket)
    else
      {:error, :invalid_issue_id} ->
        {:noreply, put_flash(socket, :error, "That issue could not be found.")}

      {:error, :invalid_review_count} ->
        {:noreply, put_flash(socket, :error, "Choose between zero and three reviews.")}
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
         false <- MapSet.member?(socket.assigns.label_writes_in_flight, {issue_id, name}) do
      issue = Operations.get_issue!(issue_id)
      actor = socket.assigns.actor

      {:noreply,
       socket
       |> update(:label_writes_in_flight, &MapSet.put(&1, {issue_id, name}))
       |> start_async({:issue_label, issue_id, name}, fn ->
         IssueLabels.toggle(issue.repository, issue, name, actor)
       end)}
    else
      _busy -> {:noreply, socket}
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
      _error -> {:noreply, put_flash(socket, :error, "That suggestion could not be dismissed.")}
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

  defp approve_directly(issue_id, review_count, socket) do
    issue_id
    |> Operations.approve_issue_directly(socket.assigns.actor, review_count)
    |> approval_result(review_count, socket, "Started directly, without a preparation round.")
  end

  defp approve_issue(issue_id, review_count, socket) do
    issue_id
    |> Operations.approve_issue(socket.assigns.actor, review_count)
    |> approval_result(review_count, socket, "Approved.")
  end

  defp approval_result(outcome, review_count, socket, prefix) do
    case outcome do
      {:ok, _job} ->
        DispatchPoller.wake()

        review_message =
          if is_integer(review_count) do
            "#{review_count} review #{if(review_count == 1, do: "pass", else: "passes")}"
          else
            "the repository's default review count"
          end

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
        {:noreply, put_flash(socket, :error, "Choose between zero and three reviews.")}

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

  defp parse_review_count(nil), do: {:ok, nil}

  defp parse_review_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {count, ""} when count in 0..3 -> {:ok, count}
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
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

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

  def primary_issue_action(_item, _group), do: nil

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
    do: not Operations.worktree_consumes_execution_slot?(allocation)

  def discardable_worktree?(_allocation), do: false

  def required_reviews(repository), do: ReviewPolicy.default_count(repository)

  def job_review_label(job, repository) do
    count = ReviewPolicy.job_count(job, repository)
    "#{count} review #{if(count == 1, do: "pass", else: "passes")}"
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

  defp load_dashboard(socket) do
    repositories = Operations.list_repositories()
    selected_repository = socket.assigns.selected_repository

    issues =
      Operations.dashboard_issues(state: "open")
      |> filter_repository(selected_repository, & &1.issue.repository)

    follow_ups =
      Operations.follow_up_items()
      |> filter_repository(selected_repository, & &1.repository)

    assign(socket,
      repositories: repositories,
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
