defmodule PtcManagerWeb.ConfigurationLive do
  use PtcManagerWeb, :live_view

  import PtcManagerWeb.RepositoryDisplay

  alias PtcManager.MaintainerActions
  alias PtcManager.Operations
  alias PtcManager.Operations.Repository
  alias PtcManager.Publications
  alias PtcManager.Repository.Health
  alias PtcManager.CapacitySettings

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:repository_form, to_form(%{}, as: :repository))
     |> assign(looked_up: nil, prefilled_branch: nil, add_repository_open: false)
     |> load_configuration()}
  end

  @impl true
  def handle_info({:operations_changed, source}, socket)
      when source in [Repository, Operations, PtcManager.GitHub.Sync, CapacitySettings],
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
           "#{full_name(repository)} added disabled. Verify its checkout, GitHub access, gate, and automations before enabling it."
         )
         |> assign(:repository_form, to_form(%{}, as: :repository))
         |> assign(looked_up: nil, prefilled_branch: nil, add_repository_open: false)
         |> load_configuration()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:repository_form, to_form(params, as: :repository))
         |> assign(:add_repository_open, true)
         |> put_flash(:error, repository_error(reason))}
    end
  end

  # The browser toggles <details> itself; the assign follows it so a re-render
  # from a live update does not close the form under the maintainer.
  def handle_event("toggle-add-repository", _params, socket),
    do: {:noreply, update(socket, :add_repository_open, &(!&1))}

  # Prefills the branch from GitHub once owner and name are both entered, unless
  # the maintainer already typed a branch of their own. The last prefilled value
  # is kept apart from the last lookup, so a failed lookup in between does not
  # turn a prefill into what looks like a typed branch.
  def handle_event("lookup-repository", %{"repository" => params}, socket) do
    key = {String.trim(params["github_owner"] || ""), String.trim(params["github_name"] || "")}
    # A re-render would otherwise drop the browser's open state of the form.
    socket = assign(socket, :add_repository_open, true)

    if elem(key, 0) == "" or elem(key, 1) == "" or key == socket.assigns.looked_up do
      {:noreply, assign(socket, :repository_form, to_form(params, as: :repository))}
    else
      typed = params["default_branch"] || ""

      {params, prefilled} =
        case Operations.lookup_github_default_branch(elem(key, 0), elem(key, 1)) do
          {:ok, branch} ->
            if typed in ["", socket.assigns.prefilled_branch],
              do: {Map.put(params, "default_branch", branch), branch},
              else: {params, socket.assigns.prefilled_branch}

          {:error, _reason} ->
            {params, socket.assigns.prefilled_branch}
        end

      {:noreply,
       socket
       |> assign(looked_up: key, prefilled_branch: prefilled)
       |> assign(:repository_form, to_form(params, as: :repository))}
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
      repository_health:
        Map.new(repositories, fn repository ->
          summary = Health.summarize(repository, Map.fetch!(availability, repository.id))
          {repository.id, Health.overall(summary)}
        end)
    )
  end

  defp repository_error(:repository_not_found),
    do:
      "GitHub could not find that exact owner/name repository, or the configured credentials cannot access it. Check the spelling and repository access."

  defp repository_error(:invalid_branch),
    do:
      "Use a branch name of letters, digits, and . _ / - that does not start with - or /, end with . or /, or contain .. or @{."

  defp repository_error(:github_unavailable),
    do:
      "GitHub access is currently unavailable. Check the configured credentials and connectivity, then try again."

  defp repository_error(:unsafe_repository_name),
    do:
      "Enter the owner and the repository name in their own fields, using only letters, digits, dots, underscores and hyphens. A pasted URL, or an owner/name pair in one field, cannot form a /srv/<owner>/<name> checkout path."

  defp repository_error(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :local_path),
      do:
        "Another configured repository already uses this repository's derived /srv/<owner>/<name> checkout path.",
      else: "The repository configuration is invalid or already exists."
  end

  defp repository_error(_reason), do: "The repository configuration is invalid or already exists."
end
