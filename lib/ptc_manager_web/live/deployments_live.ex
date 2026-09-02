defmodule PtcManagerWeb.DeploymentsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.Deployments

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: PtcManager.Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Deployments")
     |> assign(:actor, session["actor"] || "maintainer")
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

  @impl true
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load(socket)}

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

  def state_classes(state) when state in ~w(completed), do: "bg-teal-400/15 text-teal-200"
  def state_classes(state) when state in ~w(failed cancelled), do: "bg-rose-400/15 text-rose-200"
  def state_classes(_state), do: "bg-amber-400/15 text-amber-200"

  defp reason_text(:deployment_not_available), do: "deployment is not enabled for this repository"

  defp reason_text(:deployment_runner_not_configured),
    do: "the host deployment runner is not configured"

  defp reason_text(reason), do: inspect(reason, limit: 8, printable_limit: 300)
end
