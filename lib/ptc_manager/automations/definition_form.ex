defmodule PtcManager.Automations.DefinitionForm do
  @moduledoc """
  The changeset behind the create and detail pages' settings form.

  It validates the maintainer-facing fields (name, description, prompt, agent
  choice, GitHub access, queue lane, resource class, timeout in minutes, and
  the internal key of a new automation) and translates them into the identity
  and version attributes the context stores. Fields a maintainer cannot change
  in the page, such as the target type and execution profile, are copied from
  the current version.
  """

  import Ecto.Changeset

  alias PtcManager.Automations.{Definition, DefinitionVersion}

  @types %{
    key: :string,
    name: :string,
    description: :string,
    prompt: :string,
    agent_mode: :string,
    agent_kind: :string,
    github_access: :string,
    queue_lane: :string,
    resource_class: :string,
    timeout_minutes: :integer
  }

  @agent_modes [
    {"Any available agent", "any"},
    {"Prefer a kind", "prefer"},
    {"Only this kind", "require"}
  ]

  @github_access [
    {"None", "none"},
    {"Read", "read"},
    {"Full gh CLI", "trusted_direct"},
    {"Brokered publish (built-in only)", "brokered_publish"}
  ]

  @queue_lanes [{"Planning", "planning"}, {"Writing", "writing"}]
  @resource_classes [{"Light", "light"}, {"Heavy", "heavy"}]

  @execution_profiles %{
    "generic_ephemeral" => "Read-only snapshot of the default branch",
    "ephemeral_investigation" => "Disposable test-capable investigation worktree",
    "retained_pr_repair" => "Retained pull-request worktree",
    "implementation_job" => "Writable implementation worktree",
    "private_daily_update" => "Private daily update"
  }

  def agent_modes, do: @agent_modes
  def github_access_options, do: @github_access
  def queue_lanes, do: @queue_lanes
  def resource_classes, do: @resource_classes
  def execution_profile_label(profile), do: Map.get(@execution_profiles, profile, profile)

  def agent_mode_label(mode), do: option_label(@agent_modes, mode)
  def github_access_label(value), do: option_label(@github_access, value)

  @doc "Parameters for a new automation before the maintainer has typed anything."
  def new_params do
    %{
      "key" => "",
      "name" => "",
      "description" => "",
      "prompt" => "",
      "agent_mode" => "any",
      "agent_kind" => "",
      "github_access" => "read",
      "queue_lane" => "planning",
      "resource_class" => "light",
      "timeout_minutes" => "30"
    }
  end

  @doc "Parameters mirroring a definition's current version."
  def params(%Definition{current_version: %DefinitionVersion{} = version} = definition) do
    selector = version.agent_selector || %{}

    %{
      "key" => definition.key,
      "name" => definition.name,
      "description" => definition.description,
      "prompt" => version.prompt,
      "agent_mode" => selector["mode"] || "any",
      "agent_kind" => selector["preferred_kind"] || "",
      "github_access" => version.github_access,
      "queue_lane" => version.queue_lane,
      "resource_class" => version.resource_class,
      "timeout_minutes" => to_string(minutes(version.timeout_seconds))
    }
  end

  @doc """
  Validates form parameters. Options: `new?` requires and validates the key,
  `taken_names` rejects a name another automation in the repository uses.
  """
  def changeset(params, opts \\ []) when is_map(params) do
    {%{}, @types}
    |> cast(params, Map.keys(@types))
    |> update_change(:name, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> update_change(:key, &String.trim/1)
    |> validate_required([
      :name,
      :description,
      :prompt,
      :agent_mode,
      :github_access,
      :queue_lane,
      :resource_class,
      :timeout_minutes
    ])
    |> validate_length(:name, max: 160)
    |> validate_length(:description, max: 2_000)
    |> validate_inclusion(:agent_mode, Enum.map(@agent_modes, &elem(&1, 1)))
    |> validate_inclusion(:github_access, Enum.map(@github_access, &elem(&1, 1)))
    |> validate_inclusion(:queue_lane, Enum.map(@queue_lanes, &elem(&1, 1)))
    |> validate_inclusion(:resource_class, Enum.map(@resource_classes, &elem(&1, 1)))
    |> validate_number(:timeout_minutes, greater_than: 0, less_than_or_equal_to: 1_440)
    |> validate_agent_kind()
    |> validate_key(Keyword.get(opts, :new?, false))
    |> validate_name_available(Keyword.get(opts, :taken_names, []))
  end

  @doc "Identity attributes for `Automations.update_definition/4` or `create_definition/4`."
  def identity_attrs(%Ecto.Changeset{} = changeset, opts \\ []) do
    values = apply_changes(changeset)
    attrs = %{name: values.name, description: values.description}

    if Keyword.get(opts, :new?, false),
      do: Map.merge(attrs, %{key: values.key, enabled: false}),
      else: attrs
  end

  @doc "Version attributes, keeping the fields a maintainer cannot edit from the current version."
  def version_attrs(%Ecto.Changeset{} = changeset, current) do
    values = apply_changes(changeset)

    %{
      target_type: fixed(current, :target_type, "repository"),
      execution_profile: fixed(current, :execution_profile, "generic_ephemeral"),
      agent_selector: agent_selector(values),
      github_access: values.github_access,
      queue_lane: values.queue_lane,
      resource_class: values.resource_class,
      lock_policy: fixed(current, :lock_policy, %{"type" => "definition"}),
      timeout_seconds: values.timeout_minutes * 60,
      result_type: fixed(current, :result_type, "repository_report"),
      result_protocol_version: fixed(current, :result_protocol_version, 1),
      prompt: values.prompt,
      configuration_snapshot: fixed(current, :configuration_snapshot, %{})
    }
  end

  def minutes(seconds) when is_integer(seconds), do: div(seconds + 59, 60)
  def minutes(_seconds), do: 30

  defp agent_selector(%{agent_mode: "any"}),
    do: %{"mode" => "any", "preferred_kind" => nil, "required_capabilities" => []}

  defp agent_selector(values),
    do: %{
      "mode" => values.agent_mode,
      "preferred_kind" => values.agent_kind,
      "required_capabilities" => []
    }

  defp validate_agent_kind(changeset) do
    if get_field(changeset, :agent_mode) == "any" do
      changeset
    else
      validate_required(changeset, [:agent_kind], message: "choose the agent kind")
    end
  end

  defp validate_key(changeset, false), do: changeset

  defp validate_key(changeset, true) do
    changeset
    |> validate_required([:key])
    |> validate_format(:key, ~r/\A[a-z][a-z0-9_]*\z/,
      message: "must be lowercase letters, digits, and underscores, starting with a letter"
    )
    |> validate_length(:key, max: 80)
  end

  defp validate_name_available(changeset, []), do: changeset

  defp validate_name_available(changeset, taken_names) do
    taken = Enum.map(taken_names, &String.downcase/1)

    validate_change(changeset, :name, fn :name, name ->
      if String.downcase(name) in taken,
        do: [name: "is already used by another automation in this repository"],
        else: []
    end)
  end

  defp fixed(nil, _field, default), do: default
  defp fixed(%DefinitionVersion{} = current, field, _default), do: Map.fetch!(current, field)

  defp option_label(options, value) do
    case List.keyfind(options, value, 1) do
      {label, _value} -> label
      nil -> value || "—"
    end
  end
end
