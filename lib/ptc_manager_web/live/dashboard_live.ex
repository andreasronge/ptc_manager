defmodule PtcManagerWeb.DashboardLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Dispatch.Poller, as: DispatchPoller
  alias PtcManager.Manager
  alias PtcManager.MergeDecisions
  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog, as: ActionCatalog
  alias PtcManager.MaintainerActions.Poller, as: MaintainerActionPoller
  alias PtcManager.Operations
  alias PtcManager.Publications
  alias PtcManager.PublicationStatusPoller
  alias PtcManager.PublisherPoller
  alias PtcManager.ResultReconciler

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Operations.subscribe()
      Process.send_after(self(), :tick, 1_000)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:now, DateTime.utc_now())
     |> assign(:github_syncing, false)
     |> assign(:investigating, MapSet.new())
     |> assign(:reconciling_results, MapSet.new())
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

  def handle_event("investigate", %{"issue-id" => issue_id}, socket) do
    with true <- Manager.enabled?(),
         {issue_id, ""} <- Integer.parse(issue_id),
         false <- MapSet.member?(socket.assigns.investigating, issue_id) do
      {:noreply,
       socket
       |> update(:investigating, &MapSet.put(&1, issue_id))
       |> start_async({:investigate, issue_id}, fn -> Manager.investigate_issue(issue_id) end)}
    else
      false -> {:noreply, put_flash(socket, :error, "The private manager is not enabled.")}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("approve", %{"issue-id" => issue_id}, socket) do
    with {issue_id, ""} <- Integer.parse(issue_id) do
      approve_issue(issue_id, socket)
    else
      _ -> {:noreply, put_flash(socket, :error, "That issue could not be found.")}
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

  def handle_event("approve-merge", %{"publication-id" => publication_id}, socket) do
    with {publication_id, ""} <- Integer.parse(publication_id),
         {:ok, _approval} <-
           MergeDecisions.approve(publication_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Approved for merge at this exact PR version.")
       |> load_dashboard()}
    else
      {:error, :merge_analysis_missing} ->
        {:noreply, put_flash(socket, :error, "Prepare a private merge decision first.")}

      {:error, :merge_not_ready} ->
        {:noreply, put_flash(socket, :error, "The current analysis does not recommend merging.")}

      {:error, :merge_analysis_stale} ->
        {:noreply,
         put_flash(socket, :error, "The PR changed. Prepare a new merge decision first.")}

      {:error, :pull_request_is_draft} ->
        {:noreply,
         put_flash(socket, :error, "A draft pull request cannot be approved for merge.")}

      _error ->
        {:noreply,
         put_flash(socket, :error, "The exact PR version could not be approved safely.")}
    end
  end

  defp approve_issue(issue_id, socket) do
    case Operations.approve_issue(issue_id, socket.assigns.actor) do
      {:ok, _job} ->
        DispatchPoller.wake()

        {:noreply,
         socket
         |> put_flash(:info, "Approved. One implementation job is now queued.")
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approval failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
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

  def handle_async({:investigate, issue_id}, {:ok, result}, socket) do
    socket =
      socket
      |> update(:investigating, &MapSet.delete(&1, issue_id))
      |> load_dashboard()

    case result do
      {:ok, _proposal} ->
        {:noreply, put_flash(socket, :info, "Private issue analysis is ready.")}

      {:error, :repository_path_missing} ->
        {:noreply, put_flash(socket, :error, "Configure the repository's local path first.")}

      {:error, :repository_path_unavailable} ->
        {:noreply,
         put_flash(socket, :error, "The configured repository checkout is unavailable.")}

      {:error, :issue_closed} ->
        {:noreply, put_flash(socket, :error, "This issue has already been closed.")}

      {:error, :manager_busy} ->
        {:noreply,
         put_flash(socket, :error, "The private manager is already investigating another issue.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The private analysis could not be completed.")}
    end
  end

  def handle_async({:investigate, issue_id}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:investigating, &MapSet.delete(&1, issue_id))
     |> put_flash(:error, "The private analysis stopped unexpectedly.")}
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

  def elapsed(now, started_at) do
    seconds = max(DateTime.diff(now, started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
    end
  end

  def fresh?(%{proposal: nil}), do: false

  def fresh?(%{issue: issue, proposal: proposal}) do
    issue.content_digest == proposal.source_digest and
      DateTime.compare(issue.github_updated_at, proposal.source_updated_at) == :eq
  end

  def approvable?(
        %{issue: %{state: "open"}, proposal: %{readiness: "ready"}, active_job: nil} = item
      ),
      do:
        fresh?(item) and not item.issue.workflow_label_conflict and
          not claimed?(item.issue) and
          item.issue.github_assignment_projected and
          item.issue.workflow_label in [nil, "ptc:ready"] and
          item.issue.dependencies_projected and
          not item.issue.dependency_overflow and
          implementation_dependencies_resolved?(item.dependencies)

  def approvable?(_item), do: false

  def investigating?(investigating, issue_id), do: MapSet.member?(investigating, issue_id)

  def claimed?(%{github_assignees: %{"logins" => [_login | _rest]}}), do: true
  def claimed?(_issue), do: false

  def claim_label(%{github_assignees: %{"logins" => logins}}) when is_list(logins) do
    "Taken by " <> Enum.map_join(logins, ", ", &"@#{&1}")
  end

  def active_agent_action?(%{state: state}) when state in ["queued", "running", "sync_pending"],
    do: true

  def active_agent_action?(_action), do: false
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

  def agent_action_failure(%{state: "failed", last_error: error}) when is_binary(error), do: error
  def agent_action_failure(_action), do: nil

  def merge_approvable?(%{
        publication: publication,
        pr_analysis: analysis,
        merge_approval: nil
      })
      when not is_nil(publication) and not is_nil(analysis) do
    publication.state == "published" and publication.pr_state == "open" and
      analysis.outcome == "merge-ready" and analysis.head_sha == publication.remote_head_sha and
      analysis.reviewed_base_sha == publication.remote_base_sha and
      analysis.diff_digest == publication.diff_digest
  end

  def merge_approvable?(_item), do: false

  def merge_approval_fresh?(%{publication: publication, merge_approval: approval})
      when not is_nil(publication) and not is_nil(approval) do
    approval.head_sha == publication.remote_head_sha and
      approval.reviewed_base_sha == publication.remote_base_sha and
      approval.diff_digest == publication.diff_digest
  end

  def merge_approval_fresh?(_item), do: false

  def reconciling_result?(jobs, job_id), do: MapSet.member?(jobs, job_id)
  def job_label("ready_for_pr"), do: "waiting for PR publication"
  def job_label("pr_open"), do: "PR open"
  def job_label(state), do: state |> String.replace("_", " ")

  def sync_label(%{sync_status: "syncing"}), do: "syncing"
  def sync_label(%{sync_status: "ok"}), do: "connected"
  def sync_label(%{sync_status: "error"}), do: "needs attention"
  def sync_label(_repository), do: "not synchronized"

  def sync_classes(%{sync_status: "ok"}), do: "text-teal-300"
  def sync_classes(%{sync_status: "error"}), do: "text-rose-300"
  def sync_classes(_repository), do: "text-amber-300"

  def short_time(nil), do: "never"
  def short_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

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
          do: Application.get_env(:ptc_manager, :implementation_agent_capacity, 1),
          else: 0
    end
  end

  def occupied_worktrees(worker),
    do: Enum.count(worker.worktree_allocations, &(&1.state != "removed"))

  def worktree_state_label(state), do: state |> String.replace("_", " ")

  def required_reviews(repository) do
    Application.get_env(:ptc_manager, :required_pre_pr_reviews_override) ||
      repository.required_pre_pr_reviews
  end

  def state_classes("working"), do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"
  def state_classes("blocked"), do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"
  def state_classes("failed"), do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"
  def state_classes("lost"), do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"
  def state_classes("reconciling"), do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"

  def state_classes("sync_pending"),
    do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"

  def state_classes("awaiting_reconciliation"),
    do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"

  def state_classes("verifying_result"),
    do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"

  def state_classes("ready_for_pr"),
    do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"

  def state_classes("publishing_pr"),
    do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"

  def state_classes("pr_open"),
    do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"

  def state_classes("publish_blocked"),
    do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"

  def state_classes("done"), do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"
  def state_classes(_state), do: "bg-slate-400/10 text-slate-300 ring-white/10"

  def agent_publication?(%{publication: %{source: "agent"}}), do: true
  def agent_publication?(%{active_job: %{publication_source: "agent"}}), do: true
  def agent_publication?(_item), do: false

  def agent_name(run) do
    case run.agent_name do
      name when is_binary(name) and name != "" -> name
      _name -> "Agent"
    end
  end

  def dependency_status(%{issue: nil}), do: "not synchronized"
  def dependency_status(%{issue: %{state: "closed"}}), do: "completed"

  def dependency_status(%{active_job: %{state: state}}),
    do: job_label(state)

  def dependency_status(%{issue: %{state: "open"}}), do: "open"

  def dependencies_resolved?(dependencies) do
    dependencies != [] and Enum.all?(dependencies, &match?(%{issue: %{state: "closed"}}, &1))
  end

  defp implementation_dependencies_resolved?(dependencies) do
    Enum.all?(dependencies, &match?(%{issue: %{state: "closed"}}, &1))
  end

  def dependency_url(_repository, %{issue: %{html_url: html_url}}), do: html_url

  def dependency_url(repository, %{number: number}) do
    "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{number}"
  end

  defp load_dashboard(socket) do
    assign(socket,
      repositories: Operations.list_repositories(),
      issues: Operations.dashboard_issues(),
      active_agent_runs: Operations.list_active_agent_runs(),
      recent_agent_runs: Operations.list_recent_agent_runs(),
      workers: Operations.list_workers_with_worktrees(),
      manager_enabled: Manager.enabled?(),
      agent_actions_enabled: MaintainerActions.enabled?(),
      dispatch_enabled: Application.get_env(:ptc_manager, :dispatch_enabled, false),
      agent_pr_enabled:
        Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false),
      publication_enabled: Application.get_env(:ptc_manager, :publication_enabled, false),
      pr_reconcile_enabled:
        Application.get_env(:ptc_manager, :pr_reconcile_enabled, false) or
          Publications.agent_reconciliation_needed?()
    )
  end

  defp decode_agent_action_result(%{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> result
      _result -> %{}
    end
  end

  defp decode_agent_action_result(_action), do: %{}
end
