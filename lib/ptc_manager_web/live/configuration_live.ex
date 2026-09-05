defmodule PtcManagerWeb.ConfigurationLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.MaintainerActions
  alias PtcManager.Operations
  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.Operations.AgentEnvironmentVariable
  alias PtcManager.Operations.Repository
  alias PtcManager.Publications
  alias PtcManager.Repository.Health
  alias PtcManager.Repository.MaintainerLabels
  alias PtcManager.CapacitySettings

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:repository_form, to_form(%{"default_branch" => "main"}, as: :repository))
     |> assign(:remove_repository, nil)
     |> load_configuration()}
  end

  @impl true
  def handle_info({:operations_changed, source}, socket)
      when source in [
             Repository,
             Operations,
             AgentEnvironmentVariable,
             PtcManager.GitHub.Sync,
             CapacitySettings
           ],
      do: {:noreply, load_configuration(socket)}

  def handle_info({:operations_changed, _source}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add-repository", %{"repository" => params}, socket) do
    attrs = %{
      github_owner: params["github_owner"],
      github_name: params["github_name"],
      default_branch: params["default_branch"],
      enabled: false
    }

    case Operations.onboard_repository(attrs) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{repository.github_owner}/#{repository.github_name} added disabled. Verify its checkout, GitHub access, gate, and automations before enabling it."
         )
         |> assign(:repository_form, to_form(%{"default_branch" => "main"}, as: :repository))
         |> load_configuration()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:repository_form, to_form(params, as: :repository))
         |> put_flash(:error, repository_error(reason))}
    end
  end

  def handle_event("set-repository-enabled", %{"id" => id, "enabled" => enabled}, socket) do
    with {repository_id, ""} <- Integer.parse(id),
         {:ok, repository} <-
           Operations.set_repository_enabled(
             repository_id,
             enabled == "true",
             socket.assigns.actor
           ) do
      message =
        if repository.enabled,
          do:
            "#{repository.github_owner}/#{repository.github_name} is enabled. Synchronization now covers it; review its automations before approving agent work.",
          else:
            "#{repository.github_owner}/#{repository.github_name} is disabled. No new synchronization or agent work will start for it."

      {:noreply, socket |> put_flash(:info, message) |> load_configuration()}
    else
      {:error, :repository_not_found} ->
        {:noreply, put_flash(socket, :error, "That repository is no longer configured.")}

      _invalid ->
        {:noreply, put_flash(socket, :error, "The repository could not be updated.")}
    end
  end

  def handle_event("prepare-repositories", _params, socket) do
    case PtcManager.Repository.Provisioning.start() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Preparing every configured checkout on the host. Reload in a moment; each repository's service access shows what is still outstanding."
         )
         |> load_configuration()}

      {:error, :repository_provisioning_not_configured} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This host has no repository provisioning unit installed. Deploy once to install it."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The host could not start repository provisioning.")}
    end
  end

  def handle_event("confirm-remove-repository", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :remove_repository, Operations.get_repository(String.to_integer(id)))}
  end

  def handle_event("cancel-remove-repository", _params, socket),
    do: {:noreply, assign(socket, :remove_repository, nil)}

  def handle_event(
        "remove-repository",
        %{"id" => id},
        %{assigns: %{remove_repository: %{id: confirmed_id}}} = socket
      ) do
    if id == Integer.to_string(confirmed_id) do
      remove_confirmed_repository(socket, confirmed_id)
    else
      {:noreply, put_flash(socket, :error, "Confirm the repository before removing it.")}
    end
  end

  def handle_event("remove-repository", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Confirm the repository before removing it.")}

  def handle_event("add-maintainer-label", %{"label" => params}, socket) do
    with {repository_id, ""} <- Integer.parse(params["repository_id"] || ""),
         %Repository{} = repository <- Operations.get_repository(repository_id),
         {:ok, labels} <- MaintainerLabels.add(repository, params["name"], params["role"]),
         {:ok, _repository} <-
           Operations.update_maintainer_labels(repository_id, labels, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Added #{params["name"]}. It must already exist on GitHub for the toggle to work."
       )
       |> load_configuration()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, label_error(reason))}
      _invalid -> {:noreply, put_flash(socket, :error, label_error(:invalid_label_name))}
    end
  end

  def handle_event("remove-maintainer-label", %{"id" => id, "name" => name}, socket) do
    with {repository_id, ""} <- Integer.parse(id),
         %Repository{} = repository <- Operations.get_repository(repository_id),
         {:ok, _repository} <-
           Operations.update_maintainer_labels(
             repository_id,
             MaintainerLabels.remove(repository, name),
             socket.assigns.actor
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "#{name} is no longer a maintainer label here. GitHub is unchanged.")
       |> load_configuration()}
    else
      _invalid -> {:noreply, put_flash(socket, :error, "That label could not be removed.")}
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

  def handle_event(
        "save-agent-environment-variable",
        %{"repository-id" => repository_id, "variable" => params},
        socket
      ) do
    attrs = %{"name" => params["name"], "value" => params["secret"]}

    case AgentEnvironmentVariables.put(repository_id, attrs, socket.assigns.actor) do
      {:ok, _variable} ->
        {:noreply,
         socket
         |> put_flash(:info, "Implementation-agent variable saved.")
         |> load_configuration()}

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          if changeset.errors[:name],
            do: "Use an allowed uppercase variable name.",
            else: "Provide a non-empty value."

        {:noreply, put_flash(socket, :error, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The variable could not be saved. Try again.")}
    end
  end

  def handle_event(
        "delete-agent-environment-variable",
        %{"repository-id" => repository_id, "id" => id},
        socket
      ) do
    case AgentEnvironmentVariables.delete(repository_id, id, socket.assigns.actor) do
      {:ok, _variable} ->
        {:noreply,
         socket
         |> put_flash(:info, "Implementation-agent variable deleted.")
         |> load_configuration()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "The variable no longer exists.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The variable could not be deleted. Try again.")}
    end
  end

  defp remove_confirmed_repository(socket, confirmed_id) do
    case Operations.remove_repository(confirmed_id) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> assign(:remove_repository, nil)
         |> put_flash(
           :info,
           "#{repository.github_owner}/#{repository.github_name} was removed from PtcManager. Its GitHub repository and server files were not changed."
         )
         |> load_configuration()}

      {:error, :active_work} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This repository has active managed work. Wait for it to finish or cancel it before removing the repository."
         )}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:remove_repository, nil)
         |> put_flash(:error, "The repository could not be removed.")}
    end
  end

  defp load_configuration(socket) do
    repositories = Operations.list_repositories()
    availability = PtcManager.Repository.Checkout.availability(repositories)
    repository_ids = MapSet.new(repositories, & &1.id)

    remove_repository =
      case socket.assigns[:remove_repository] do
        %{id: id} = repository ->
          if MapSet.member?(repository_ids, id), do: repository, else: nil

        _repository ->
          nil
      end

    assign(socket,
      remove_repository: remove_repository,
      repositories: repositories,
      capacity_setting: CapacitySettings.current(),
      agent_actions_enabled: MaintainerActions.enabled?(),
      dispatch_enabled: Application.get_env(:ptc_manager, :dispatch_enabled, false),
      agent_pr_enabled:
        Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false),
      publication_enabled: Application.get_env(:ptc_manager, :publication_enabled, false),
      pr_reconcile_enabled:
        Application.get_env(:ptc_manager, :pr_reconcile_enabled, false) or
          Publications.agent_reconciliation_needed?(),
      agent_environment_variables:
        Map.new(repositories, fn repository ->
          {repository.id, AgentEnvironmentVariables.list_metadata(repository.id)}
        end),
      repository_health:
        Enum.map(repositories, &Health.summarize(&1, Map.fetch!(availability, &1.id)))
    )
  end

  def maintainer_labels(repository), do: MaintainerLabels.list(repository)

  defp label_error(:invalid_label_role), do: "Choose either badge or park."

  defp label_error(:reserved_label_name),
    do: "Names starting with ptc: belong to PtcManager's own display projection."

  defp label_error(:label_already_configured), do: "That label is already configured here."
  defp label_error(:too_many_labels), do: "Twenty maintainer labels per repository is the limit."

  defp label_error(_reason),
    do:
      "Use 1 to 50 characters from letters, digits, spaces, and . _ / : - for a GitHub label name."

  def sync_label(%{sync_status: "syncing"}), do: "syncing"
  def sync_label(%{sync_status: "ok"}), do: "connected"
  def sync_label(%{sync_status: "error"}), do: "needs attention"
  def sync_label(_repository), do: "not synchronized"

  def sync_classes(%{sync_status: "ok"}), do: "text-teal-300"
  def sync_classes(%{sync_status: "error"}), do: "text-rose-300"
  def sync_classes(_repository), do: "text-amber-300"

  def health_classes(:ready), do: "bg-teal-400/15 text-teal-200"
  def health_classes(:attention), do: "bg-amber-400/15 text-amber-200"
  def health_classes(:syncing), do: "bg-sky-400/15 text-sky-200"
  def health_classes(:unchecked), do: "bg-white/5 text-slate-400"

  def health_detail(%{detail: %DateTime{} = value}), do: Calendar.strftime(value, "%d %b · %H:%M")
  def health_detail(%{detail: nil}), do: "No detail recorded."
  def health_detail(%{detail: detail}), do: detail

  defp repository_error(:repository_not_found),
    do:
      "GitHub could not find that exact owner/name repository, or the configured credentials cannot access it. Check the spelling and repository access."

  defp repository_error(:github_unavailable),
    do:
      "GitHub access is currently unavailable. Check the configured credentials and connectivity, then try again."

  defp repository_error(:unsafe_repository_name),
    do:
      "Enter the owner and the repository name in their own fields, using only letters, digits, dots, underscores and hyphens. A pasted URL, or an owner/name pair in one field, cannot form a single /srv checkout path."

  defp repository_error(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :local_path),
      do:
        "Another configured repository already uses this repository name's derived /srv checkout path.",
      else: "The repository configuration is invalid or already exists."
  end

  defp repository_error(_reason), do: "The repository configuration is invalid or already exists."

  def variable_set_at(%DateTime{} = value), do: Calendar.strftime(value, "%d %b %Y · %H:%M")
end
