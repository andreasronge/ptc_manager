defmodule PtcManagerWeb.ConfigurationLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.Operations
  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.Health
  alias PtcManager.CapacitySettings

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     |> assign(:actor, session["actor"] || "maintainer")
     |> load_configuration()}
  end

  @impl true
  def handle_info({:operations_changed, source}, socket)
      when source in [Repository, PtcManager.GitHub.Sync, CapacitySettings],
      do: {:noreply, load_configuration(socket)}

  def handle_info({:operations_changed, _source}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add-repository", %{"repository" => params}, socket) do
    attrs = %{
      github_owner: params["github_owner"],
      github_name: params["github_name"],
      default_branch: params["default_branch"],
      local_path: params["local_path"],
      enabled: false
    }

    case Operations.create_repository(attrs) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{repository.github_owner}/#{repository.github_name} added disabled. Verify its checkout, GitHub access, gate, and automations before enabling it."
         )
         |> load_configuration()}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The repository configuration is invalid or already exists."
         )}
    end
  end

  def handle_event("save-capacity", %{"capacity" => params}, socket) do
    case CapacitySettings.update(params) do
      {:ok, _setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Worker capacity updated. Queued work will use the new limits.")
         |> load_configuration()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, "Use a whole number from 1 to 8 for all three limits.")}
    end
  end

  defp load_configuration(socket) do
    repositories = Operations.list_repositories()
    availability = PtcManager.Repository.Checkout.availability(repositories)

    assign(socket,
      capacity_setting: CapacitySettings.current(),
      repository_health:
        Enum.map(repositories, &Health.summarize(&1, Map.fetch!(availability, &1.id)))
    )
  end

  def health_classes(:ready), do: "bg-teal-400/15 text-teal-200"
  def health_classes(:attention), do: "bg-amber-400/15 text-amber-200"
  def health_classes(:syncing), do: "bg-sky-400/15 text-sky-200"
  def health_classes(:unchecked), do: "bg-white/5 text-slate-400"

  def health_detail(%{detail: %DateTime{} = value}), do: Calendar.strftime(value, "%d %b · %H:%M")
  def health_detail(%{detail: nil}), do: "No detail recorded."
  def health_detail(%{detail: detail}), do: detail
end
