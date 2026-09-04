defmodule PtcManagerWeb.DeploymentsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.{Deployments, Toolchain}
  alias PtcManagerWeb.TimeFormat

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      PtcManager.Operations.subscribe()
      Process.send_after(self(), :deployment_tick, 30_000)
    end

    {:ok,
     socket
     |> assign(:page_title, "Deployments")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:now, DateTime.utc_now())
     |> assign(:revision_results, %{})
     |> load()}
  end

  @impl true
  def handle_event("refresh-revisions", _params, socket) do
    {:noreply, load(socket, refresh?: true)}
  end

  def handle_event("deploy", %{"repository-id" => id}, socket) do
    with {repository_id, ""} <- Integer.parse(id),
         repository when not is_nil(repository) <-
           PtcManager.Operations.get_repository(repository_id),
         {:ok, _deployment} <- Deployments.request(repository, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Deployment queued. New work is paused while active agents finish.")
       |> load()}
    else
      {:error, :deployment_already_requested} ->
        {:noreply, put_flash(socket, :error, "Another deployment is already queued or running.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Deployment could not be queued: #{reason_text(reason)}")}

      _invalid ->
        {:noreply, put_flash(socket, :error, "Repository is no longer available.")}
    end
  end

  def handle_event("cancel-deployment", %{"id" => id}, socket) do
    with {deployment_id, ""} <- Integer.parse(id),
         {:ok, _deployment} <- Deployments.cancel(deployment_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Deployment cancelled. New work resumes.")
       |> load()}
    else
      {:error, :deployment_not_cancellable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The host runner has already started; wait for it to finish."
         )}

      _invalid ->
        {:noreply, put_flash(socket, :error, "The deployment could not be cancelled.")}
    end
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load(socket)}

  def handle_info(:deployment_tick, socket) do
    Process.send_after(self(), :deployment_tick, 30_000)
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_async({:latest_revision, repository_id}, {:ok, {:ok, sha}}, socket) do
    {:noreply,
     socket
     |> update(:revision_results, &Map.put(&1, repository_id, {:ok, sha}))
     |> assign_statuses()}
  end

  def handle_async({:latest_revision, repository_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> update(:revision_results, &Map.put(&1, repository_id, {:error, reason}))
     |> assign_statuses()}
  end

  def handle_async({:latest_revision, repository_id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> update(:revision_results, &Map.put(&1, repository_id, {:error, reason}))
     |> assign_statuses()}
  end

  defp load(socket, opts \\ []) do
    configured = Deployments.configured_repositories()
    repositories = Enum.map(configured, &elem(&1, 0))

    socket =
      socket
      |> assign(:repositories, repositories)
      |> assign(:recent_deployments, Deployments.list_recent())
      |> assign(:toolchain, Toolchain.report())
      |> assign_statuses()

    if connected?(socket) do
      Enum.reduce(repositories, socket, fn repository, acc ->
        if Keyword.get(opts, :refresh?, false) or
             not Map.has_key?(acc.assigns.revision_results, repository.id) do
          source = Application.fetch_env!(:ptc_manager, :deployment_revision_source)

          start_async(acc, {:latest_revision, repository.id}, fn ->
            PtcManager.Gateway.call(source, :latest, [repository])
          end)
        else
          acc
        end
      end)
    else
      socket
    end
  end

  defp assign_statuses(socket) do
    statuses =
      Enum.map(socket.assigns[:repositories] || [], fn repository ->
        result = Map.get(socket.assigns.revision_results, repository.id, :loading)
        latest_sha = if match?({:ok, _sha}, result), do: elem(result, 1)

        Deployments.update_status(repository, latest_sha)
        |> Map.put(:revision_result, result)
      end)

    assign(socket, :deployment_statuses, statuses)
  end

  @doc "An exact UTC instant, so a deployment can be matched against host logs."
  def timestamp(nil), do: nil
  def timestamp(at), do: Calendar.strftime(at, "%d %b %Y · %H:%M:%S UTC")

  @doc "How long ago something happened, in the reader's own terms."
  def since(now, at), do: TimeFormat.relative(now, at)

  @doc """
  How long the deployment took, or has been running.

  A deployment that never started has no duration to report: the time between
  requesting it and giving up is the wait, not the work.
  """
  def deployment_duration(_now, %{started_at: nil}), do: nil

  def deployment_duration(now, %{started_at: started_at, finished_at: finished_at}),
    do: TimeFormat.duration(now, started_at, finished_at)

  def short_sha(nil), do: "Unknown"
  def short_sha(sha), do: String.slice(sha, 0, 12)

  def state_label("queued"), do: "Queued"
  def state_label("draining"), do: "Waiting for agents"
  def state_label("starting"), do: "Starting"
  def state_label("running"), do: "Deploying"
  def state_label("completed"), do: "Deployed"
  def state_label("failed"), do: "Failed"
  def state_label("cancelled"), do: "Cancelled"
  def state_label(state), do: state

  def outcome_classes("completed"), do: "border-teal-400/20 bg-teal-400/[0.07] text-teal-100"

  def outcome_classes(state) when state in ~w(failed cancelled),
    do: "border-rose-400/25 bg-rose-400/[0.07] text-rose-100"

  def outcome_classes(_state), do: "border-white/10 bg-white/[0.035] text-slate-200"

  @doc """
  What the machine runs, compared with what this release pins.

  Staged is not drift: Herdr is installed before its link moves, because the
  link moves only when `ptc_manager-herdr` restarts.
  """
  def program_label(:matched), do: "Pinned version"
  def program_label(:staged), do: "Installed, awaiting restart"
  def program_label(:drifted), do: "Not this release"
  def program_label(:absent), do: "Not on this machine"

  def program_classes(:matched), do: "bg-teal-400/15 text-teal-200"
  def program_classes(:staged), do: "bg-amber-400/15 text-amber-200"
  def program_classes(:drifted), do: "bg-rose-400/15 text-rose-200"
  def program_classes(:absent), do: "bg-white/5 text-slate-500"

  def toolchain_note(:matched),
    do: "Every program on the machine is the version this release pins."

  def toolchain_note(:staged),
    do:
      "A pinned program is installed but not linked yet. Herdr takes effect when ptc_manager-herdr restarts with no agent session retained."

  def toolchain_note(:drifted),
    do:
      "The machine runs a program this release does not pin. Deploy this revision to replace it, or pin what the machine runs in deploy/toolchain-versions."

  def toolchain_note(:absent),
    do: "This machine links none of these programs, so there is nothing to compare."

  def state_classes(state) when state in ~w(completed), do: "bg-teal-400/15 text-teal-200"
  def state_classes(state) when state in ~w(failed cancelled), do: "bg-rose-400/15 text-rose-200"
  def state_classes(_state), do: "bg-amber-400/15 text-amber-200"

  defp reason_text(:deployment_not_available), do: "deployment is not enabled for this repository"

  defp reason_text(:deployment_runner_not_configured),
    do: "the host deployment runner is not configured"

  defp reason_text(reason), do: inspect(reason, limit: 8, printable_limit: 300)
end
