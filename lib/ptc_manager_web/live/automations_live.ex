defmodule PtcManagerWeb.AutomationsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.Automations
  alias PtcManager.Automations.{Defaults, DefinitionForm, DefinitionVersion, Schedule, Trigger}
  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.GenericHerdrAdapter
  alias PtcManager.Operations
  alias PtcManagerWeb.TimeFormat

  embed_templates "automations_live/*"

  @runs_page 20
  @latest_runs 5

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Automations")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:repositories, [])
     |> assign(:selected_repository, nil)
     |> assign(:repo_param, nil)
     |> assign(:now, DateTime.utc_now())
     |> assign(:definition, nil)
     |> assign(:advanced_open?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    repositories = Operations.list_repositories()
    selected = valid_repository_key(repositories, params["repo"])

    socket =
      assign(socket,
        repositories: repositories,
        selected_repository: selected,
        repo_param: repo_param(repositories, params["repo"]),
        now: DateTime.utc_now()
      )

    case socket.assigns.live_action do
      :index -> {:noreply, load_index(socket)}
      :new -> {:noreply, load_new(socket, params)}
      :show -> show_params(socket, params)
    end
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket) do
    socket = assign(socket, :now, DateTime.utc_now())

    case socket.assigns.live_action do
      :index -> {:noreply, load_index(socket)}
      :show -> {:noreply, refresh_show(socket)}
      :new -> {:noreply, socket}
    end
  end

  # Shared events ------------------------------------------------------------

  @impl true
  def handle_event("toggle-definition", %{"id" => id, "enabled" => enabled}, socket) do
    definition = Automations.get_definition!(String.to_integer(id))

    case Automations.update_identity(definition, %{enabled: enabled == "true"}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{updated.name} #{if updated.enabled, do: "enabled", else: "paused"}."
         )
         |> reload()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("toggle-advanced", _params, socket),
    do: {:noreply, assign(socket, :advanced_open?, !socket.assigns.advanced_open?)}

  # Detail page: header and prompt ------------------------------------------

  def handle_event("run", %{"trigger-id" => id}, socket) do
    with {trigger_id, ""} <- Integer.parse(id),
         %Trigger{} = trigger <- Automations.get_trigger!(trigger_id),
         {:ok, _invocation} <- Automations.run_trigger(trigger, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Automation queued. You can follow it below or in Operations.")
       |> refresh_show()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
      _invalid -> {:noreply, put_flash(socket, :error, "That automation trigger is unavailable.")}
    end
  end

  def handle_event("show-prompt-preview", _params, socket),
    do: {:noreply, assign(socket, :preview_open?, true)}

  def handle_event("close-prompt-preview", _params, socket),
    do: {:noreply, assign(socket, :preview_open?, false)}

  def handle_event("restore-suggested-prompt", _params, socket) do
    definition = socket.assigns.definition
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
         socket
         |> put_flash(:info, "PtcManager's suggested prompt was restored.")
         |> refresh_show()
         |> reset_settings_form()}

      nil ->
        {:noreply,
         put_flash(socket, :error, "This custom automation has no built-in suggestion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Detail page: settings form ----------------------------------------------

  def handle_event("validate-settings", %{"automation" => params}, socket),
    do: {:noreply, assign(socket, :settings_form, settings_form(socket, params, :validate))}

  def handle_event("save-settings", %{"automation" => params}, socket) do
    definition = socket.assigns.definition
    changeset = DefinitionForm.changeset(params, taken_names: taken_names(socket))

    with true <- changeset.valid?,
         {:ok, _version} <-
           Automations.update_definition(
             definition,
             DefinitionForm.identity_attrs(changeset),
             DefinitionForm.version_attrs(changeset, definition.current_version),
             socket.assigns.actor
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Saved as a new immutable automation version.")
       |> refresh_show()
       |> reset_settings_form()}
    else
      false ->
        {:noreply, assign(socket, :settings_form, settings_form(socket, params, :validate))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Detail page: triggers ---------------------------------------------------

  def handle_event("toggle-trigger", %{"id" => id, "enabled" => enabled}, socket) do
    trigger = Automations.get_trigger!(String.to_integer(id))

    case Automations.update_trigger(trigger, %{enabled: enabled == "true"}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{trigger_name(updated)} #{if updated.enabled, do: "enabled", else: "paused"}."
         )
         |> refresh_show()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("toggle-trigger-editor", %{"id" => id}, socket) do
    trigger_id = String.to_integer(id)
    open = socket.assigns.open_trigger_ids

    if MapSet.member?(open, trigger_id) do
      {:noreply, assign(socket, :open_trigger_ids, MapSet.delete(open, trigger_id))}
    else
      {:noreply, open_trigger_editor(socket, trigger!(socket, trigger_id))}
    end
  end

  def handle_event("add-trigger", %{"type" => type}, socket) do
    definition = socket.assigns.definition

    case Automations.create_trigger(definition, new_trigger_attrs(type, definition)) do
      {:ok, trigger} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{trigger_name(trigger)} added paused. Enable it when it is ready.")
         |> refresh_show()
         |> open_trigger_editor(trigger)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("delete-trigger", %{"id" => id}, socket) do
    trigger = trigger!(socket, String.to_integer(id))

    if Automations.default_trigger?(socket.assigns.definition, trigger) do
      {:noreply, put_flash(socket, :error, "Built-in triggers can be paused but not removed.")}
    else
      case Automations.delete_trigger(trigger) do
        {:ok, _trigger} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{trigger_name(trigger)} removed.")
           |> refresh_show()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end
  end

  def handle_event("validate-trigger", %{"trigger_id" => id} = params, socket) do
    trigger = trigger!(socket, String.to_integer(id))
    form = trigger_form(trigger, trigger_params(trigger, params), :validate)
    {:noreply, put_trigger_form(socket, trigger.id, form)}
  end

  def handle_event("save-trigger", %{"trigger_id" => id} = params, socket) do
    trigger = trigger!(socket, String.to_integer(id))
    form = trigger_form(trigger, trigger_params(trigger, params), :validate)

    with true <- form.source.valid?,
         {:ok, attrs} <- trigger_attrs(trigger, form.source),
         {:ok, _trigger} <- Automations.update_trigger(trigger, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, "#{trigger_name(trigger)} saved.")
       |> assign(:open_trigger_ids, MapSet.delete(socket.assigns.open_trigger_ids, trigger.id))
       |> refresh_show()}
    else
      false -> {:noreply, put_trigger_form(socket, trigger.id, form)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Detail page: runs, copies -----------------------------------------------

  def handle_event("toggle-run", %{"id" => id}, socket) do
    run_id = String.to_integer(id)
    open = socket.assigns.open_run_ids

    open =
      if MapSet.member?(open, run_id),
        do: MapSet.delete(open, run_id),
        else: MapSet.put(open, run_id)

    {:noreply, assign(socket, :open_run_ids, open)}
  end

  def handle_event("show-more-runs", _params, socket) do
    {:noreply,
     socket
     |> assign(:runs_limit, socket.assigns.runs_limit + @runs_page)
     |> load_runs()}
  end

  def handle_event("duplicate", %{"repository-id" => repository_id}, socket) do
    target = repository!(socket, repository_id)

    case Automations.duplicate_definition(socket.assigns.definition, target, socket.assigns.actor) do
      {:ok, _definition} ->
        {:noreply, put_flash(socket, :info, "Copied to #{repository_key(target)} as disabled.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Create page -------------------------------------------------------------

  def handle_event("validate-new", %{"automation" => params} = event, socket) do
    key_edited? = socket.assigns.key_edited? or event["_target"] == ["automation", "key"]
    repository = new_repository(socket, params["repository_id"])
    params = derive_key(params, repository, key_edited?)

    {:noreply,
     socket
     |> assign(:key_edited?, key_edited?)
     |> assign(:new_repository, repository)
     |> assign(:new_form, new_form(repository, params, :validate))}
  end

  def handle_event("create", %{"automation" => params}, socket) do
    repository = new_repository(socket, params["repository_id"])
    params = derive_key(params, repository, socket.assigns.key_edited?)
    changeset = new_changeset(repository, params)

    with true <- changeset.valid?,
         {:ok, definition} <-
           Automations.create_definition(
             repository,
             DefinitionForm.identity_attrs(changeset, new?: true),
             DefinitionForm.version_attrs(changeset, nil),
             socket.assigns.actor
           ),
         {:ok, _trigger} <-
           Automations.create_trigger(definition, new_trigger_attrs("manual", definition)) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Automation created paused. Review the prompt and triggers, then enable it."
       )
       |> push_navigate(to: page_path(:show, id: definition.id, repo: socket.assigns.repo_param))}
    else
      false ->
        {:noreply,
         socket
         |> assign(:new_repository, repository)
         |> assign(:new_form, to_form(%{changeset | action: :validate}, as: :automation))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  # Navigation --------------------------------------------------------------

  @doc "Builds an Automations path, dropping blank query parameters."
  def page_path(action, params \\ [])
  def page_path(:index, params), do: with_query("/automations", params)
  def page_path(:new, params), do: with_query("/automations/new", params)

  def page_path(:show, params) do
    {id, params} = Keyword.pop!(params, :id)
    with_query("/automations/#{id}", params)
  end

  defp with_query(base, params) do
    query =
      params
      |> Enum.reject(fn {_key, value} -> value in [nil, "", false] end)
      |> URI.encode_query()

    if query == "", do: base, else: base <> "?" <> query
  end

  # Presentation helpers ----------------------------------------------------

  def repository_key(repository), do: "#{repository.github_owner}/#{repository.github_name}"

  def timestamp(nil), do: "—"
  def timestamp(value), do: Calendar.strftime(value, "%d %b · %H:%M UTC")

  def local_time(nil, _time_zone), do: "Not scheduled"

  def local_time(value, time_zone) do
    case DateTime.shift_zone(value, time_zone || "Etc/UTC", Tz.TimeZoneDatabase) do
      {:ok, local} -> Calendar.strftime(local, "%a %d %b · %H:%M %Z")
      _error -> timestamp(value)
    end
  end

  def occurrence_label(%{local: local, utc: utc}) do
    "#{Calendar.strftime(local, "%a %d %b · %H:%M %Z")} (#{Calendar.strftime(utc, "%H:%M UTC")})"
  end

  def relative(now, value), do: TimeFormat.relative(now, value)

  def agent_label(%DefinitionVersion{agent_selector: selector}) do
    kind = selector["preferred_kind"]

    case selector["mode"] do
      "prefer" when is_binary(kind) and kind != "" -> "Prefer #{kind}"
      "require" when is_binary(kind) and kind != "" -> "Only #{kind}"
      _any -> "Any"
    end
  end

  def profile_label(profile), do: DefinitionForm.execution_profile_label(profile)
  def access_label(value), do: DefinitionForm.github_access_label(value)
  def minutes_label(seconds), do: "#{DefinitionForm.minutes(seconds)} min"

  def trigger_name(%Trigger{trigger_type: "manual"}), do: "Run now"
  def trigger_name(%Trigger{trigger_type: "schedule"}), do: "Schedule"
  def trigger_name(%Trigger{trigger_type: "contextual"}), do: "Button"

  def trigger_title(%Trigger{trigger_type: "manual"} = trigger), do: trigger.label

  def trigger_title(%Trigger{trigger_type: "schedule"} = trigger),
    do: "#{Schedule.describe(trigger.cron_expression)} · #{trigger.time_zone}"

  def trigger_title(%Trigger{trigger_type: "contextual"} = trigger),
    do: "“#{trigger.label}” on #{Automations.surface_label(trigger.surface)}"

  def trigger_detail(trigger, automation_enabled \\ true)

  def trigger_detail(%Trigger{trigger_type: "schedule", enabled: enabled}, automation_enabled)
      when not enabled or not automation_enabled,
      do: "Paused · no runs scheduled"

  def trigger_detail(%Trigger{trigger_type: "schedule"} = trigger, _automation_enabled),
    do: "Next " <> local_time(trigger.next_run_at, trigger.time_zone)

  def trigger_detail(%Trigger{trigger_type: "manual"}, _automation_enabled),
    do: "Queues a run from this page."

  def trigger_detail(%Trigger{trigger_type: "contextual"}, _automation_enabled),
    do: "Appears as a maintainer action on that surface."

  def sorted_triggers(triggers) do
    Enum.sort_by(triggers, &{trigger_order(&1.trigger_type), &1.id})
  end

  defp trigger_order("schedule"), do: 0
  defp trigger_order("manual"), do: 1
  defp trigger_order(_type), do: 2

  def offer_manual?(definition),
    do: not Enum.any?(definition.triggers, &(&1.trigger_type == "manual"))

  def offer_schedule?(definition), do: definition.current_version.target_type == "repository"

  def offer_button?(definition) do
    case Automations.surface_for_target(definition.current_version.target_type) do
      nil ->
        false

      surface ->
        not Enum.any?(
          definition.triggers,
          &(&1.trigger_type == "contextual" and &1.surface == surface)
        )
    end
  end

  def manual_trigger(definition),
    do: Enum.find(definition.triggers, &(&1.trigger_type == "manual" and &1.enabled))

  def next_schedule(definition) do
    definition.triggers
    |> Enum.filter(&(&1.trigger_type == "schedule" and &1.enabled and &1.next_run_at))
    |> Enum.min_by(&DateTime.to_unix(&1.next_run_at), fn -> nil end)
  end

  def schedule_preview(form), do: Schedule.preview(form.source)

  @doc "The editor form for a trigger whose editor is open, as a list so templates can iterate it."
  def editor_forms(open_ids, forms, trigger) do
    if MapSet.member?(open_ids, trigger.id), do: List.wrap(forms[trigger.id]), else: []
  end

  def surface_options(definition) do
    expected = Automations.surface_for_target(definition.current_version.target_type)

    Enum.map(["planning_issue", "delivery_pr"], fn surface ->
      {Automations.surface_label(surface), surface, surface != expected}
    end)
  end

  def time_zone_options do
    Enum.map(Schedule.time_zones(), &{&1, &1}) ++
      [{"Other…", Schedule.other_time_zone_option()}]
  end

  def weekday_options, do: Enum.map(Schedule.weekdays(), fn {number, name} -> {name, number} end)
  def preset_options, do: Enum.map(Schedule.presets(), fn {value, label} -> {label, value} end)

  @doc "Agent kinds a maintainer can pick: reported by online workers, configured, or currently stored."
  def agent_kind_options(workers, current_kind) do
    online =
      workers
      |> Enum.filter(&(&1.status == "online"))
      |> Enum.flat_map(&List.wrap((&1.capabilities || %{})["agent_kinds"]))
      |> MapSet.new()

    configured = :ptc_manager |> Application.get_env(:agent_profiles, %{}) |> Map.keys()

    kinds =
      [current_kind | configured]
      |> Enum.concat(online)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn kind ->
        if MapSet.member?(online, kind), do: {kind, kind}, else: {"#{kind} (offline)", kind}
      end)

    [{"Choose a kind…", ""} | kinds]
  end

  def run_state_label("daily_digest", "no_changes"), do: "Quiet day"
  def run_state_label(_key, state), do: state

  def state_classes(state) when state in ["succeeded", "no_changes"],
    do: "bg-teal-400/15 text-teal-200"

  def state_classes(state) when state in ["failed", "blocked", "cancelled"],
    do: "bg-rose-400/15 text-rose-200"

  def state_classes(state) when state in ["running", "synchronizing"],
    do: "bg-sky-400/15 text-sky-200"

  def state_classes(_state), do: "bg-amber-400/15 text-amber-200"

  def run_title(invocation),
    do:
      "#{String.capitalize(invocation.trigger_type)} run · v#{invocation.automation_definition_version.version}"

  def markdown_html(markdown, opts \\ []),
    do: PtcManagerWeb.DailyDigestLive.markdown_html(markdown, opts)

  def prompt_preview(definition) do
    version = definition.current_version

    prompt =
      Catalog.preview(definition.key, version.prompt, definition.repository) ||
        generic_prompt_preview(definition, version.prompt)

    maybe_add_result_protocol(prompt, version.execution_profile)
  end

  # Components --------------------------------------------------------------

  attr :id, :string, required: true
  attr :enabled, :boolean, required: true
  attr :event, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true

  def switch(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      role="switch"
      aria-checked={to_string(@enabled)}
      aria-label={@label}
      title={if(@enabled, do: "Enabled · click to pause", else: "Paused · click to enable")}
      phx-disable-with=""
      phx-click={@event}
      phx-value-id={@value}
      phx-value-enabled={to_string(!@enabled)}
      class={[
        "relative inline-flex h-6 w-11 shrink-0 items-center rounded-full border transition",
        @enabled && "border-teal-300/40 bg-teal-400",
        !@enabled && "border-white/10 bg-white/10"
      ]}
    >
      <span class={[
        "inline-block size-4 rounded-full bg-white shadow transition-transform",
        @enabled && "translate-x-6",
        !@enabled && "translate-x-1"
      ]}>
      </span>
    </button>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :hint, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(placeholder required readonly disabled min max step pattern)

  def text_field(assigns) do
    assigns = assign(assigns, :errors, field_errors(assigns.field))

    ~H"""
    <label class={["block text-xs text-slate-400", @class]}>
      {@label}
      <input
        type={@type}
        id={@field.id}
        name={@field.name}
        value={Phoenix.HTML.Form.normalize_value(@type, @field.value)}
        class={[
          "mt-1 w-full rounded-lg border bg-slate-950 p-2 text-sm text-white",
          @errors == [] && "border-white/10",
          @errors != [] && "border-rose-400/60"
        ]}
        {@rest}
      />
      <.field_hint hint={@hint} errors={@errors} />
    </label>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :hint, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled required)

  def select_field(assigns) do
    assigns = assign(assigns, :errors, field_errors(assigns.field))

    ~H"""
    <label class={["block text-xs text-slate-400", @class]}>
      {@label}
      <select
        id={@field.id}
        name={@field.name}
        class={[
          "mt-1 w-full rounded-lg border bg-slate-950 p-2 text-sm text-white disabled:opacity-50",
          @errors == [] && "border-white/10",
          @errors != [] && "border-rose-400/60"
        ]}
        {@rest}
      >
        <option
          :for={option <- @options}
          value={option_value(option)}
          selected={to_string(option_value(option)) == to_string(@field.value)}
          disabled={option_disabled?(option)}
        >
          {elem(option, 0)}
        </option>
      </select>
      <.field_hint hint={@hint} errors={@errors} />
    </label>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :rows, :integer, default: 8
  attr :hint, :string, default: nil
  attr :class, :string, default: nil

  def textarea_field(assigns) do
    assigns = assign(assigns, :errors, field_errors(assigns.field))

    ~H"""
    <label class={["block text-xs text-slate-400", @class]}>
      {@label}
      <textarea
        id={@field.id}
        name={@field.name}
        rows={@rows}
        class={[
          "mt-1 w-full rounded-lg border bg-slate-950 p-3 font-mono text-xs leading-5 text-white",
          @errors == [] && "border-white/10",
          @errors != [] && "border-rose-400/60"
        ]}
      >{Phoenix.HTML.Form.normalize_value("textarea", @field.value)}</textarea>
      <.field_hint hint={@hint} errors={@errors} />
    </label>
    """
  end

  attr :hint, :string, default: nil
  attr :errors, :list, default: []

  defp field_hint(assigns) do
    ~H"""
    <span :for={error <- @errors} class="mt-1 block text-xs text-rose-300">{error}</span>
    <span :if={@hint && @errors == []} class="mt-1 block leading-5 text-slate-500">{@hint}</span>
    """
  end

  defp field_errors(field) do
    if Phoenix.Component.used_input?(field),
      do: Enum.map(field.errors, &translate_error/1),
      else: []
  end

  defp option_value({_label, value}), do: value
  defp option_value({_label, value, _disabled}), do: value
  defp option_disabled?({_label, _value, disabled}), do: disabled
  defp option_disabled?(_option), do: false

  # Loading -----------------------------------------------------------------

  defp reload(%{assigns: %{live_action: :index}} = socket), do: load_index(socket)
  defp reload(%{assigns: %{live_action: :show}} = socket), do: refresh_show(socket)
  defp reload(socket), do: socket

  defp load_index(socket) do
    selected = selected_repositories(socket)

    groups =
      Enum.map(selected, fn repository ->
        definitions = Automations.list_definitions(repository)
        latest = Automations.latest_invocation_by_definition(repository)

        rows =
          Enum.map(definitions, fn definition ->
            %{
              definition: definition,
              summary: Automations.trigger_summary(definition),
              last_run: latest[definition.id],
              next_run: next_schedule(definition)
            }
          end)

        {repository, rows}
      end)

    latest_runs =
      case selected do
        [repository] when socket.assigns.selected_repository != nil ->
          Automations.list_invocations(repository, @latest_runs)

        _repositories ->
          nil
      end

    assign(socket, groups: groups, latest_runs: latest_runs)
  end

  defp show_params(socket, %{"id" => id}) do
    definition = Automations.get_definition!(parse_id!(id))
    key = repository_key(definition.repository)
    selected = socket.assigns.selected_repository

    cond do
      selected != nil and selected != key ->
        {:noreply, push_navigate(socket, to: page_path(:index, repo: socket.assigns.repo_param))}

      socket.assigns.definition && socket.assigns.definition.id == definition.id ->
        {:noreply, refresh_show(socket)}

      true ->
        {:noreply, load_show(socket, definition)}
    end
  end

  defp load_show(socket, definition) do
    socket
    |> assign(:page_title, definition.name)
    |> assign(:definition, definition)
    |> assign(:built_in?, Automations.built_in?(definition))
    |> assign(:preview_open?, false)
    |> assign(:advanced_open?, false)
    |> assign(:open_trigger_ids, MapSet.new())
    |> assign(:trigger_forms, %{})
    |> assign(:open_run_ids, MapSet.new())
    |> assign(:runs_limit, @runs_page)
    |> assign(:workers, Operations.list_workers())
    |> reset_settings_form()
    |> load_runs()
  end

  defp refresh_show(socket) do
    definition = Automations.get_definition!(socket.assigns.definition.id)

    socket
    |> assign(:definition, definition)
    |> assign(:workers, Operations.list_workers())
    |> load_runs()
  end

  defp load_runs(socket) do
    limit = socket.assigns.runs_limit

    runs =
      Automations.list_invocations_for_definition(socket.assigns.definition, limit: limit + 1)

    assign(socket, runs: Enum.take(runs, limit), more_runs?: length(runs) > limit)
  end

  defp load_new(socket, params) do
    repository =
      new_repository(socket, params["repository_id"]) ||
        Enum.find(
          socket.assigns.repositories,
          &(repository_key(&1) == socket.assigns.selected_repository)
        ) ||
        List.first(socket.assigns.repositories)

    form_params = DefinitionForm.new_params()

    socket
    |> assign(:page_title, "New automation")
    |> assign(:new_repository, repository)
    |> assign(:key_edited?, false)
    |> assign(:workers, Operations.list_workers())
    |> assign(:new_form, new_form(repository, form_params, nil))
  end

  defp reset_settings_form(socket) do
    definition = socket.assigns.definition
    assign(socket, :settings_form, settings_form(socket, DefinitionForm.params(definition), nil))
  end

  defp settings_form(socket, params, action) do
    params
    |> DefinitionForm.changeset(taken_names: taken_names(socket))
    |> Map.put(:action, action)
    |> to_form(as: :automation)
  end

  defp taken_names(%{assigns: %{definition: definition}}) when not is_nil(definition) do
    definition.repository
    |> Automations.list_definitions()
    |> Enum.reject(&(&1.id == definition.id))
    |> Enum.map(& &1.name)
  end

  defp taken_names(_socket), do: []

  defp new_changeset(nil, params), do: DefinitionForm.changeset(params, new?: true)

  defp new_changeset(repository, params) do
    taken = repository |> Automations.list_definitions() |> Enum.map(& &1.name)

    params
    |> DefinitionForm.changeset(new?: true, taken_names: taken)
    |> validate_key_available(repository)
  end

  defp new_form(repository, params, action) do
    repository
    |> new_changeset(params)
    |> Map.put(:action, action)
    |> to_form(as: :automation)
  end

  defp validate_key_available(changeset, repository) do
    key = Ecto.Changeset.get_field(changeset, :key)

    if is_binary(key) and key != "" and Automations.get_definition(repository, key) do
      Ecto.Changeset.add_error(changeset, :key, "is already used in this repository")
    else
      changeset
    end
  end

  defp derive_key(params, nil, _key_edited?), do: params
  defp derive_key(params, _repository, true), do: params

  defp derive_key(params, repository, false),
    do: Map.put(params, "key", Automations.slug_key(repository, params["name"] || ""))

  defp new_repository(socket, id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> Enum.find(socket.assigns.repositories, &(&1.id == parsed))
      _invalid -> nil
    end
  end

  defp new_repository(_socket, _id), do: nil

  # Triggers ----------------------------------------------------------------

  defp open_trigger_editor(socket, trigger) do
    socket
    |> assign(:open_trigger_ids, MapSet.put(socket.assigns.open_trigger_ids, trigger.id))
    |> put_trigger_form(trigger.id, trigger_form(trigger, nil, nil))
  end

  defp put_trigger_form(socket, trigger_id, form),
    do: assign(socket, :trigger_forms, Map.put(socket.assigns.trigger_forms, trigger_id, form))

  defp trigger_form(%Trigger{trigger_type: "schedule"} = trigger, params, action) do
    (params || Schedule.params(trigger))
    |> Schedule.changeset()
    |> Map.put(:action, action)
    |> to_form(as: :schedule)
  end

  defp trigger_form(%Trigger{} = trigger, params, action) do
    trigger
    |> Trigger.changeset(params || %{})
    |> Map.put(:action, action)
    |> to_form(as: :trigger)
  end

  defp trigger_params(%Trigger{trigger_type: "schedule"}, params), do: params["schedule"] || %{}

  defp trigger_params(%Trigger{trigger_type: "contextual"} = trigger, params) do
    values = params["trigger"] || %{}

    expected =
      Automations.surface_for_target(trigger.automation_definition.current_version.target_type)

    %{"label" => values["label"], "surface" => values["surface"] || expected}
  end

  defp trigger_params(%Trigger{}, params), do: %{"label" => (params["trigger"] || %{})["label"]}

  defp trigger_attrs(%Trigger{trigger_type: "schedule"}, changeset),
    do: Schedule.trigger_attrs(changeset)

  defp trigger_attrs(%Trigger{trigger_type: "contextual"} = trigger, changeset) do
    expected =
      Automations.surface_for_target(trigger.automation_definition.current_version.target_type)

    surface = Ecto.Changeset.get_field(changeset, :surface)

    if surface == expected,
      do: {:ok, %{label: Ecto.Changeset.get_field(changeset, :label), surface: surface}},
      else: {:error, :surface_mismatch}
  end

  defp trigger_attrs(%Trigger{}, changeset),
    do: {:ok, %{label: Ecto.Changeset.get_field(changeset, :label)}}

  defp new_trigger_attrs("manual", _definition),
    do: %{
      trigger_type: "manual",
      surface: "automations",
      label: "Run now",
      enabled: false,
      configuration: %{}
    }

  defp new_trigger_attrs("schedule", _definition), do: Schedule.new_trigger_attrs()

  defp new_trigger_attrs("button", definition) do
    %{
      trigger_type: "contextual",
      surface: Automations.surface_for_target(definition.current_version.target_type),
      label: definition.name,
      enabled: false,
      configuration: %{}
    }
  end

  defp trigger!(socket, trigger_id) do
    trigger = Automations.get_trigger!(trigger_id)

    if trigger.automation_definition_id == socket.assigns.definition.id,
      do: trigger,
      else: raise(Ecto.NoResultsError, queryable: Trigger)
  end

  # Repositories ------------------------------------------------------------

  defp selected_repositories(%{assigns: %{repositories: repositories, selected_repository: nil}}),
    do: repositories

  defp selected_repositories(%{assigns: %{repositories: repositories, selected_repository: key}}),
    do: Enum.filter(repositories, &(repository_key(&1) == key))

  defp valid_repository_key(repositories, key) when is_binary(key) do
    if Enum.any?(repositories, &(repository_key(&1) == key)), do: key
  end

  defp valid_repository_key(_repositories, _key), do: nil

  defp repo_param(_repositories, "all"), do: "all"
  defp repo_param(repositories, key), do: valid_repository_key(repositories, key)

  defp repository!(socket, id) do
    parsed = String.to_integer(id)
    Enum.find(socket.assigns.repositories, &(&1.id == parsed)) || raise Ecto.NoResultsError
  end

  defp parse_id!(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _invalid -> raise Ecto.NoResultsError, queryable: Automations.Definition
    end
  end

  # Prompt preview ----------------------------------------------------------

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

  defp generic_prompt_preview(definition, user_prompt) do
    repository = definition.repository

    runtime =
      ~s(<runtime_context action="#{definition.key}" repository="#{repository.github_owner}/#{repository.github_name}" default_branch="#{repository.default_branch}" invocation_marker="ptc-manager-invocation:<generated>" trigger_context="<generated>" allowed_outcomes="completed,no-changes" />)

    Automations.compose_prompt(user_prompt, runtime)
  end

  defp maybe_add_result_protocol(prompt, profile)
       when profile in ["generic_ephemeral", "ephemeral_investigation"] do
    prompt <>
      GenericHerdrAdapter.result_protocol(
        "<generated-result-path>.json",
        "<generated-result-path>.schema.json"
      )
  end

  defp maybe_add_result_protocol(prompt, _execution_profile), do: prompt

  defp error_message(%Ecto.Changeset{}), do: "The automation configuration is invalid."
  defp error_message(:surface_mismatch), do: "That button belongs on the other surface."
  defp error_message(reason), do: "Could not complete that action: #{inspect(reason)}"
end
