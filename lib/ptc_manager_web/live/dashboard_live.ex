defmodule PtcManagerWeb.DashboardLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.Operations

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
     |> load_dashboard()}
  end

  @impl true
  def handle_event("approve", %{"issue-id" => issue_id}, socket) do
    with {issue_id, ""} <- Integer.parse(issue_id) do
      approve_issue(issue_id, socket)
    else
      _ -> {:noreply, put_flash(socket, :error, "That issue could not be found.")}
    end
  end

  defp approve_issue(issue_id, socket) do
    case Operations.approve_issue(issue_id, socket.assigns.actor) do
      {:ok, _job} ->
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

  def state_classes("working"), do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"
  def state_classes("blocked"), do: "bg-amber-400/15 text-amber-300 ring-amber-400/20"
  def state_classes("failed"), do: "bg-rose-400/15 text-rose-300 ring-rose-400/20"
  def state_classes("lost"), do: "bg-violet-400/15 text-violet-300 ring-violet-400/20"
  def state_classes("done"), do: "bg-sky-400/15 text-sky-300 ring-sky-400/20"
  def state_classes(_state), do: "bg-slate-400/10 text-slate-300 ring-white/10"

  defp load_dashboard(socket) do
    assign(socket,
      issues: Operations.dashboard_issues(),
      agent_runs: Operations.list_agent_runs()
    )
  end
end
