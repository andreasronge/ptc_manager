defmodule PtcManagerWeb.RepositoryConfigurationLive do
  use PtcManagerWeb, :live_view

  import PtcManagerWeb.RepositoryDisplay

  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.Operations
  alias PtcManager.Operations.AgentEnvironmentVariable
  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.BranchPrefixes
  alias PtcManager.Repository.Health
  alias PtcManager.Repository.IntegrationBranches
  alias PtcManager.Repository.MaintainerLabels

  @impl true
  def mount(%{"id" => id}, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    socket =
      socket
      |> assign(:actor, session["actor"] || "maintainer")
      |> assign(:repository_id, parse_id(id))
      |> assign(:remove_repository?, false)

    case load_repository(socket) do
      {:ok, socket} ->
        {:ok, socket}

      :error ->
        {:ok,
         socket
         |> put_flash(:error, "That repository is no longer configured.")
         |> push_navigate(to: ~p"/configuration")}
    end
  end

  @impl true
  def handle_info({:operations_changed, source}, socket)
      when source in [
             Repository,
             Operations,
             AgentEnvironmentVariable,
             PtcManager.GitHub.Sync,
             PtcManager.CommitIdentities
           ],
      do: reload(socket)

  def handle_info({:operations_changed, _source}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set-repository-enabled", %{"enabled" => enabled}, socket) do
    case Operations.set_repository_enabled(
           socket.assigns.repository.id,
           enabled == "true",
           socket.assigns.actor
         ) do
      {:ok, repository} ->
        message =
          if repository.enabled,
            do:
              "#{full_name(repository)} is enabled. Synchronization now covers it; review its automations before approving agent work.",
            else:
              "#{full_name(repository)} is disabled. No new synchronization or agent work will start for it."

        socket |> put_flash(:info, message) |> reload()

      {:error, :repository_not_found} ->
        {:noreply, put_flash(socket, :error, "That repository is no longer configured.")}

      _invalid ->
        {:noreply, put_flash(socket, :error, "The repository could not be updated.")}
    end
  end

  def handle_event("update-default-branch", %{"branch" => %{"name" => name}}, socket) do
    case Operations.update_repository_branch(
           socket.assigns.repository.id,
           name,
           socket.assigns.actor
         ) do
      {:ok, repository} ->
        socket
        |> put_flash(:info, "New work starts from and targets #{repository.default_branch}.")
        |> reload()

      {:error, :invalid_branch} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Use a branch name of letters, digits, and . _ / - that does not start with - or /, end with . or /, or contain .. or @{."
         )}

      {:error, :active_work} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Active work, retained worktrees, or open managed pull requests still use #{socket.assigns.repository.default_branch}. Change the branch once they finish or are cleaned up."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The branch could not be changed.")}
    end
  end

  def handle_event("save-workspace-setup", %{"setup" => params}, socket) do
    timeout =
      case Integer.parse(params["timeout_minutes"] || "") do
        {value, ""} -> value
        _invalid -> nil
      end

    case Operations.update_workspace_setup(
           socket.assigns.repository.id,
           params["command"],
           timeout,
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        socket
        |> put_flash(
          :info,
          "Workspace setup saved. New worktrees run it; existing ones keep theirs."
        )
        |> reload()

      {:error, :invalid_workspace_setup} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Enter a one-line command of at most 2000 bytes and a timeout of 1 to 1440 minutes."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The workspace setup could not be saved.")}
    end
  end

  def handle_event("add-integration-branch", %{"mapping" => params}, socket) do
    case Operations.add_integration_branch(
           socket.assigns.repository.id,
           params["label"] || "",
           params["branch"] || "",
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        socket
        |> put_flash(
          :info,
          "Issues labelled #{String.trim(params["label"] || "")} now target #{String.trim(params["branch"] || "")}."
        )
        |> reload()

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mapping_error(reason))}
    end
  end

  def handle_event(
        "set-integration-branch-active",
        %{"label" => label, "active" => active},
        socket
      )
      when active in ["true", "false"] do
    case Operations.set_integration_branch_active(
           socket.assigns.repository.id,
           label,
           active == "true",
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        message =
          if active == "true",
            do: "#{label} routes to its integration branch again.",
            else:
              "#{label} is off: its issues target #{socket.assigns.repository.default_branch}."

        socket |> put_flash(:info, message) |> reload()

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mapping_error(reason))}
    end
  end

  def handle_event("remove-integration-branch", %{"label" => label}, socket) do
    case Operations.remove_integration_branch(
           socket.assigns.repository.id,
           label,
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        socket
        |> put_flash(
          :info,
          "#{label} no longer maps to an integration branch. Approved jobs keep their base."
        )
        |> reload()

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, mapping_error(reason))}
    end
  end

  def handle_event("set-default-branch-prefix", %{"prefix" => prefix}, socket) do
    case Operations.set_default_branch_prefix(
           socket.assigns.repository.id,
           prefix,
           socket.assigns.actor
         ) do
      {:ok, repository} ->
        socket
        |> put_flash(
          :info,
          "New branches start with #{BranchPrefixes.default(repository)} unless a label maps elsewhere."
        )
        |> reload()

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, prefix_error(reason))}
    end
  end

  def handle_event("add-branch-prefix", %{"mapping" => params}, socket) do
    case Operations.add_branch_prefix_mapping(
           socket.assigns.repository.id,
           params["label"] || "",
           params["prefix"] || "",
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        socket
        |> put_flash(
          :info,
          "Issues labelled #{String.trim(params["label"] || "")} now get #{String.trim(params["prefix"] || "")} branches."
        )
        |> reload()

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, prefix_error(reason))}
    end
  end

  def handle_event("remove-branch-prefix", %{"label" => label}, socket) do
    case Operations.remove_branch_prefix_mapping(
           socket.assigns.repository.id,
           label,
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        socket
        |> put_flash(
          :info,
          "#{label} no longer picks a branch prefix. Approved jobs keep theirs."
        )
        |> reload()

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, prefix_error(reason))}
    end
  end

  def handle_event("set-auto-fix", %{"enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    case PtcManager.AutoImplementation.configure(
           socket.assigns.repository.id,
           enabled == "true",
           socket.assigns.actor
         ) do
      {:ok, _repository} ->
        socket |> put_flash(:info, "Automatic implementation setting saved.") |> reload()

      _invalid ->
        handle_event("set-auto-fix", %{}, socket)
    end
  end

  def handle_event("set-auto-fix", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Could not save automatic implementation setting.")}

  def handle_event("set-auto-fix-daily-limit", %{"auto_fix" => params}, socket) do
    with {limit, ""} <- Integer.parse(params["daily_limit"] || ""),
         {:ok, _repository} <-
           PtcManager.AutoImplementation.configure_daily_limit(
             socket.assigns.repository.id,
             limit,
             socket.assigns.actor
           ) do
      socket |> put_flash(:info, "Automatic implementation daily limit saved.") |> reload()
    else
      _invalid -> handle_event("set-auto-fix-daily-limit", %{}, socket)
    end
  end

  def handle_event("set-auto-fix-daily-limit", _params, socket),
    do:
      {:noreply,
       put_flash(socket, :error, "The daily limit must be a whole number from 1 to 50.")}

  # Labels are rewritten as a whole list, so it is computed from the stored
  # repository, not this socket's copy, which may predate another session's edit.
  def handle_event("add-maintainer-label", %{"label" => params}, socket) do
    with %Repository{} = repository <- Operations.get_repository(socket.assigns.repository.id),
         {:ok, labels} <- MaintainerLabels.add(repository, params["name"], params["role"]),
         {:ok, _repository} <-
           Operations.update_maintainer_labels(repository.id, labels, socket.assigns.actor) do
      socket
      |> put_flash(
        :info,
        "Added #{params["name"]}. It must already exist on GitHub for the toggle to work."
      )
      |> reload()
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, label_error(reason))}
      nil -> reload(socket)
    end
  end

  def handle_event("remove-maintainer-label", %{"name" => name}, socket) do
    with %Repository{} = repository <- Operations.get_repository(socket.assigns.repository.id),
         {:ok, _repository} <-
           Operations.update_maintainer_labels(
             repository.id,
             MaintainerLabels.remove(repository, name),
             socket.assigns.actor
           ) do
      socket
      |> put_flash(:info, "#{name} is no longer a maintainer label here. GitHub is unchanged.")
      |> reload()
    else
      nil -> reload(socket)
      _invalid -> {:noreply, put_flash(socket, :error, "That label could not be removed.")}
    end
  end

  def handle_event("save-agent-environment-variable", %{"variable" => params}, socket) do
    attrs = %{"name" => params["name"], "value" => params["secret"]}

    case AgentEnvironmentVariables.put(
           socket.assigns.repository.id,
           attrs,
           socket.assigns.actor
         ) do
      {:ok, _variable} ->
        socket |> put_flash(:info, "Implementation-agent variable saved.") |> reload()

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

  def handle_event("delete-agent-environment-variable", %{"id" => id}, socket) do
    case AgentEnvironmentVariables.delete(socket.assigns.repository.id, id, socket.assigns.actor) do
      {:ok, _variable} ->
        socket |> put_flash(:info, "Implementation-agent variable deleted.") |> reload()

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "The variable no longer exists.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The variable could not be deleted. Try again.")}
    end
  end

  def handle_event("confirm-remove-repository", _params, socket),
    do: {:noreply, assign(socket, :remove_repository?, true)}

  def handle_event("cancel-remove-repository", _params, socket),
    do: {:noreply, assign(socket, :remove_repository?, false)}

  def handle_event("remove-repository", _params, %{assigns: %{remove_repository?: true}} = socket) do
    case Operations.remove_repository(socket.assigns.repository.id) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{full_name(repository)} was removed from PtcManager. Its GitHub repository and server files were not changed."
         )
         |> push_navigate(to: ~p"/configuration")}

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
         |> assign(:remove_repository?, false)
         |> put_flash(:error, "The repository could not be removed.")}
    end
  end

  def handle_event("remove-repository", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Confirm the repository before removing it.")}

  defp reload(socket) do
    case load_repository(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      :error ->
        {:noreply,
         socket
         |> put_flash(:error, "That repository is no longer configured.")
         |> push_navigate(to: ~p"/configuration")}
    end
  end

  defp load_repository(%{assigns: %{repository_id: nil}}), do: :error

  defp load_repository(socket) do
    case Operations.get_repository(socket.assigns.repository_id) do
      %Repository{} = repository ->
        {:ok,
         assign(socket,
           page_title: full_name(repository),
           repository: repository,
           health: Health.summarize(repository),
           commit_identity: PtcManager.CommitIdentities.resolve(repository),
           maintainer_labels: MaintainerLabels.list(repository),
           integration_branches: IntegrationBranches.list(repository),
           integration_suggestions: IntegrationBranches.suggestions(repository),
           branch_prefix_default: BranchPrefixes.default(repository),
           branch_prefix_mappings: BranchPrefixes.list(repository),
           agent_environment_variables: AgentEnvironmentVariables.list_metadata(repository.id)
         )}

      nil ->
        :error
    end
  end

  defp parse_id(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> value
      _invalid -> nil
    end
  end

  defp mapping_error(:invalid_label_name),
    do: "Use 1 to 50 characters from letters, digits, spaces, and . _ / : - for the label."

  defp mapping_error(:reserved_label_name),
    do: "Labels starting with ptc: are PtcManager's own and cannot route work."

  defp mapping_error(:invalid_branch),
    do: "Use a branch name of letters, digits, and . _ / - that does not start with - or /."

  defp mapping_error(:label_already_mapped), do: "That label already has a mapping here."
  defp mapping_error(:too_many_mappings), do: "Twenty mappings per repository is the limit."

  defp mapping_error(:branch_not_found),
    do: "GitHub reports no such branch, or the read token cannot see this repository."

  defp mapping_error(:github_unavailable),
    do: "GitHub could not confirm the branch right now. Try again."

  defp mapping_error(_reason), do: "The mapping could not be saved."

  defp prefix_error(:invalid_branch_prefix),
    do:
      "Use one to three segments of letters, digits, and . _ -, each ending in /, such as bugfix/."

  defp prefix_error(:branch_prefix_collides),
    do: "GitHub has a branch with that name, so git cannot create branches under it."

  defp prefix_error(reason), do: mapping_error(reason)

  defp label_error(:invalid_label_role), do: "Choose either badge or park."

  defp label_error(:reserved_label_name),
    do: "Names starting with ptc: belong to PtcManager's own display projection."

  defp label_error(:label_already_configured), do: "That label is already configured here."
  defp label_error(:too_many_labels), do: "Twenty maintainer labels per repository is the limit."

  defp label_error(_reason),
    do:
      "Use 1 to 50 characters from letters, digits, spaces, and . _ / : - for a GitHub label name."

  def variable_set_at(%DateTime{} = value), do: Calendar.strftime(value, "%d %b %Y · %H:%M")
end
