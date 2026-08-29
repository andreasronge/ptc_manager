defmodule PtcManagerWeb.DashboardLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Dispatch.Poller, as: DispatchPoller
  alias PtcManager.Manager
  alias PtcManager.Operations
  alias PtcManager.Publications
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

      {:noreply,
       socket
       |> put_flash(:info, "Draft PR publishing is queued again.")
       |> load_dashboard()}
    else
      _failure ->
        {:noreply, put_flash(socket, :error, "That publication could not be retried.")}
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

      {:error, :proposal_not_ready} ->
        {:noreply, put_flash(socket, :error, "This issue is not ready to start.")}

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
         put_flash(socket, :info, "Committed branch verified and ready for a draft PR.")}

      {:error, :result_already_claimed} ->
        {:noreply, put_flash(socket, :info, "This branch is already being checked.")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The committed branch is not ready yet. No GitHub write occurred."
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
      do: fresh?(item)

  def approvable?(_item), do: false

  def investigating?(investigating, issue_id), do: MapSet.member?(investigating, issue_id)
  def reconciling_result?(jobs, job_id), do: MapSet.member?(jobs, job_id)
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

  def publication_error(nil), do: "The publisher needs attention."

  def publication_error(error) do
    cond do
      String.contains?(error, "github_app_not_configured") ->
        "The GitHub App publisher is not configured."

      String.contains?(error, "remote_branch_diverged") ->
        "The remote job branch contains a different commit."

      String.contains?(error, "pull_request_already_closed") ->
        "A pull request for this job branch was already closed."

      String.contains?(error, "authoritative_diff_changed") ->
        "The GitHub-base diff no longer matches the verified result."

      true ->
        "The last publisher attempt failed safely; details are in the audit log."
    end
  end

  def state_classes("working"), do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"
  def state_classes("blocked"), do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"
  def state_classes("failed"), do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"
  def state_classes("lost"), do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"
  def state_classes("reconciling"), do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"

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

  defp load_dashboard(socket) do
    assign(socket,
      repositories: Operations.list_repositories(),
      issues: Operations.dashboard_issues(),
      agent_runs: Operations.list_agent_runs(),
      manager_enabled: Manager.enabled?(),
      dispatch_enabled: Application.get_env(:ptc_manager, :dispatch_enabled, false),
      publication_enabled: Application.get_env(:ptc_manager, :publication_enabled, false)
    )
  end
end
