defmodule PtcManagerWeb.AutomationsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.Automations
  alias PtcManager.Automations.{Defaults, DefinitionVersion, Trigger}
  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.GenericHerdrAdapter
  alias PtcManager.Operations

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Automations")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:selected_repository, nil)
     |> assign(:preview_definition_id, nil)
     |> assign(:expanded_definition_ids, MapSet.new())
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    repositories = Operations.list_repositories()
    selected = valid_repository_key(repositories, params["repo"])

    {:noreply,
     socket
     |> assign(:selected_repository, selected)
     |> load()}
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("run", %{"trigger-id" => id}, socket) do
    with {trigger_id, ""} <- Integer.parse(id),
         %Trigger{} = trigger <- Automations.get_trigger!(trigger_id),
         {:ok, _invocation} <- Automations.run_trigger(trigger, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Automation queued. You can follow it here or in Operations.")
       |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      _invalid -> {:noreply, put_flash(socket, :error, "That automation trigger is unavailable.")}
    end
  end

  def handle_event("toggle-definition", %{"id" => id, "enabled" => enabled}, socket) do
    definition = definition!(socket, id)

    case Automations.update_identity(definition, %{enabled: enabled == "true"}) do
      {:ok, _definition} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("show-prompt-preview", %{"id" => id}, socket) do
    definition = definition!(socket, id)
    {:noreply, assign(socket, :preview_definition_id, definition.id)}
  end

  def handle_event("close-prompt-preview", _params, socket),
    do: {:noreply, assign(socket, :preview_definition_id, nil)}

  def handle_event("toggle-definition-editor", %{"id" => id}, socket) do
    definition = definition!(socket, id)
    expanded = socket.assigns.expanded_definition_ids

    expanded =
      if MapSet.member?(expanded, definition.id),
        do: MapSet.delete(expanded, definition.id),
        else: MapSet.put(expanded, definition.id)

    {:noreply, assign(socket, :expanded_definition_ids, expanded)}
  end

  def handle_event("restore-suggested-prompt", %{"id" => id}, socket) do
    definition = definition!(socket, id)
    suggestion = Defaults.get(definition.repository, definition.key)

    case suggestion &&
           Automations.create_version(
             definition,
             definition.current_version
             |> version_attrs_from_current()
             |> Map.put(:prompt, suggestion.prompt),
             socket.assigns.actor
           ) do
      {:ok, _version} ->
        {:noreply,
         socket |> put_flash(:info, "PtcManager's suggested prompt was restored.") |> load()}

      nil ->
        {:noreply,
         put_flash(socket, :error, "This custom automation has no built-in suggestion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("toggle-trigger", %{"id" => id, "enabled" => enabled}, socket) do
    trigger = Automations.get_trigger!(String.to_integer(id))

    case Automations.update_trigger(trigger, %{enabled: enabled == "true"}) do
      {:ok, _trigger} -> {:noreply, load(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("save-trigger", %{"trigger_id" => id, "trigger" => params}, socket) do
    trigger = Automations.get_trigger!(String.to_integer(id))

    case Automations.update_trigger(trigger, %{
           label: params["label"],
           surface: params["surface"],
           enabled: params["enabled"] == "true"
         }) do
      {:ok, _trigger} -> {:noreply, socket |> put_flash(:info, "Button trigger saved.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("add-schedule", %{"definition-id" => id}, socket) do
    definition = definition!(socket, id)

    if definition.current_version.target_type == "repository" do
      case Automations.create_trigger(definition, %{
             trigger_type: "schedule",
             surface: "automations",
             label: "New schedule",
             enabled: false,
             configuration: %{},
             cron_expression: "0 6 * * *",
             time_zone: "Europe/Stockholm"
           }) do
        {:ok, _trigger} ->
          {:noreply,
           socket
           |> put_flash(:info, "Paused schedule added. Edit and enable it when ready.")
           |> load()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, "Schedules require a repository-level action.")}
    end
  end

  def handle_event(
        "save-definition",
        %{"definition_id" => id, "automation" => params},
        socket
      ) do
    definition = definition!(socket, id)
    current = definition.current_version

    identity = %{
      name: params["name"],
      description: params["description"],
      enabled: params["enabled"] == "true"
    }

    version = version_attrs(current, params)

    case Automations.update_definition(definition, identity, version, socket.assigns.actor) do
      {:ok, _version} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved as a new immutable automation version.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("save-schedule", %{"schedule_id" => id, "schedule" => params}, socket) do
    trigger = Automations.get_trigger!(String.to_integer(id))

    case Automations.update_trigger(trigger, %{
           label: params["label"],
           cron_expression: params["cron_expression"],
           time_zone: params["time_zone"],
           next_run_at: nil,
           enabled: params["enabled"] == "true"
         }) do
      {:ok, _trigger} ->
        {:noreply, socket |> put_flash(:info, "Schedule saved.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("create", %{"automation" => params}, socket) do
    repository = repository!(socket, params["repository_id"])

    identity = %{
      key: params["key"],
      name: params["name"],
      description: params["description"],
      enabled: false
    }

    version = %{
      target_type: "repository",
      execution_profile: "generic_ephemeral",
      agent_selector: %{"mode" => "any", "preferred_kind" => blank_nil(params["agent_kind"])},
      github_access: params["github_access"],
      queue_lane: params["queue_lane"],
      resource_class: params["resource_class"],
      lock_policy: %{"type" => "definition"},
      timeout_seconds: integer(params["timeout_seconds"], 1_800),
      result_type: "repository_report",
      result_protocol_version: 1,
      prompt: params["prompt"],
      configuration_snapshot: %{}
    }

    with {:ok, definition} <-
           Automations.create_definition(repository, identity, version, socket.assigns.actor),
         {:ok, _trigger} <-
           Automations.create_trigger(definition, %{
             trigger_type: "manual",
             surface: "automations",
             label: "Run now",
             enabled: false,
             configuration: %{}
           }) do
      {:noreply,
       socket
       |> put_flash(:info, "Automation created disabled. Review it before enabling the action.")
       |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("duplicate", %{"id" => id, "repository-id" => repository_id}, socket) do
    source = definition!(socket, id)
    target = repository!(socket, repository_id)

    case Automations.duplicate_definition(source, target, socket.assigns.actor) do
      {:ok, _definition} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Copied to #{target.github_owner}/#{target.github_name} as disabled."
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def timestamp(nil), do: "Not scheduled"
  def timestamp(value), do: Calendar.strftime(value, "%d %b · %H:%M UTC")
  def repository_key(repository), do: "#{repository.github_owner}/#{repository.github_name}"
  def short_prompt(value), do: value |> String.trim() |> String.slice(0, 180)

  def selected_definition(definitions, id) when is_integer(id),
    do: Enum.find(definitions, &(&1.id == id))

  def selected_definition(_definitions, _id), do: nil

  def prompt_preview(definition) do
    version = definition.current_version

    prompt =
      if Catalog.configurable_action?(definition.key) do
        Catalog.preview(definition.key, version.prompt, definition.repository)
      else
        generic_prompt_preview(definition, version.prompt)
      end

    maybe_add_result_protocol(prompt, version.execution_profile)
  end

  def state_classes(state) when state in ["succeeded", "no_changes"],
    do: "bg-teal-400/15 text-teal-200"

  def state_classes(state) when state in ["failed", "blocked", "cancelled"],
    do: "bg-rose-400/15 text-rose-200"

  def state_classes(state) when state in ["running", "synchronizing"],
    do: "bg-sky-400/15 text-sky-200"

  def state_classes(_state), do: "bg-amber-400/15 text-amber-200"

  defp load(socket) do
    repositories = Operations.list_repositories()

    selected_repositories =
      case socket.assigns.selected_repository do
        nil -> repositories
        key -> Enum.filter(repositories, &(repository_key(&1) == key))
      end

    definitions = Enum.flat_map(selected_repositories, &Automations.list_definitions/1)

    invocations =
      case selected_repositories do
        [repository] -> Automations.list_invocations(repository)
        _repositories -> Automations.list_all_invocations()
      end

    assign(socket,
      repositories: repositories,
      definitions: definitions,
      invocations: invocations,
      workers: Operations.list_workers()
    )
  end

  defp valid_repository_key(repositories, key) when is_binary(key) do
    if Enum.any?(repositories, &(repository_key(&1) == key)), do: key
  end

  defp valid_repository_key(_repositories, _key), do: nil

  defp definition!(socket, id) do
    parsed = String.to_integer(id)
    Enum.find(socket.assigns.definitions, &(&1.id == parsed)) || raise Ecto.NoResultsError
  end

  defp repository!(socket, id) do
    parsed = String.to_integer(id)
    Enum.find(socket.assigns.repositories, &(&1.id == parsed)) || raise Ecto.NoResultsError
  end

  defp version_attrs(%DefinitionVersion{} = current, params) do
    %{
      target_type: current.target_type,
      execution_profile: params["execution_profile"],
      agent_selector: %{
        "mode" => params["agent_mode"],
        "preferred_kind" => blank_nil(params["agent_kind"]),
        "required_capabilities" => []
      },
      github_access: params["github_access"],
      queue_lane: params["queue_lane"],
      resource_class: params["resource_class"],
      lock_policy: current.lock_policy,
      timeout_seconds: integer(params["timeout_seconds"], current.timeout_seconds),
      result_type: current.result_type,
      result_protocol_version: current.result_protocol_version,
      prompt: params["prompt"],
      configuration_snapshot: current.configuration_snapshot
    }
  end

  defp version_attrs_from_current(%DefinitionVersion{} = current) do
    current
    |> Map.from_struct()
    |> Map.take([
      :target_type,
      :execution_profile,
      :agent_selector,
      :github_access,
      :queue_lane,
      :resource_class,
      :lock_policy,
      :timeout_seconds,
      :result_type,
      :result_protocol_version,
      :prompt,
      :configuration_snapshot
    ])
  end

  defp integer(value, default) do
    case Integer.parse(value || "") do
      {parsed, ""} -> parsed
      _invalid -> default
    end
  end

  defp blank_nil(value) when value in [nil, ""], do: nil
  defp blank_nil(value), do: value

  defp generic_prompt_preview(definition, user_prompt) do
    repository = definition.repository

    runtime =
      ~s(<runtime_context action="#{definition.key}" repository="#{repository.github_owner}/#{repository.github_name}" default_branch="#{repository.default_branch}" invocation_marker="ptc-manager-invocation:<generated>" trigger_context="<generated>" allowed_outcomes="completed,no-changes" />)

    Automations.compose_prompt(user_prompt, runtime)
  end

  defp maybe_add_result_protocol(prompt, "generic_ephemeral") do
    prompt <>
      GenericHerdrAdapter.result_protocol(
        "<generated-result-path>.json",
        "<generated-result-path>.schema.json"
      )
  end

  defp maybe_add_result_protocol(prompt, _execution_profile), do: prompt

  defp error_message(%Ecto.Changeset{}), do: "The automation configuration is invalid."
  defp error_message(reason), do: "Could not complete that action: #{inspect(reason)}"
end
