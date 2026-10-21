defmodule PtcManager.Cluster.RepositorySettings do
  @moduledoc """
  The settings that move with a repository from one member to another.

  `export/1` runs on the source and `import/3` on the target, inside the claim's
  final transaction. What moves: every maintainer-editable field of the
  repository row except `enabled`, `local_path`, and synchronization state;
  each automation's current definition version and triggers, keyed by
  automation key; and the **names** of the agent environment variables. Secret
  values never leave the machine that stores them, so the target lists the
  names to re-enter.

  Every imported automation and trigger arrives paused, including ones the
  target seeded at onboarding, so nothing runs before a maintainer reviews it.
  """

  import Ecto.Query

  alias PtcManager.Automations.{Definition, DefinitionVersion, Trigger}
  alias PtcManager.Cluster.Claims
  alias PtcManager.Operations.{AgentEnvironmentVariable, AuditEvent, Repository}
  alias PtcManager.Repo

  # Fields of `Repository.changeset/2` that move with the repository.
  @transferred ~w(default_branch workspace_setup_command workspace_setup_timeout_minutes
    integration_branches github_branch_names branch_prefixes auto_fix_issues
    auto_fix_daily_limit maintainer_labels github_label_names required_pre_pr_reviews
    machine_requirements)a

  # Fields that stay: identity, the local checkout, the claim itself, and what
  # synchronization observes on each machine.
  @excluded ~w(github_owner github_name enabled local_path sync_status last_synced_at
    last_sync_error github_viewer_login github_default_branch github_branches_checked_at
    github_labels_checked_at)a

  @trigger_fields ~w(trigger_type surface label configuration cron_expression time_zone)a

  def transferred_fields, do: @transferred
  def excluded_fields, do: @excluded

  @doc "The settings document of one repository, with a digest of its content."
  def export(%Repository{} = repository) do
    definitions =
      Repo.all(
        from definition in Definition,
          where: definition.repository_id == ^repository.id and is_nil(definition.archived_at),
          order_by: definition.key,
          preload: [:current_version, :triggers]
      )

    document = %{
      "repository" => Claims.key(repository),
      "settings" =>
        Map.new(@transferred, fn field ->
          {Atom.to_string(field), Map.fetch!(repository, field)}
        end),
      "automations" => Enum.map(definitions, &export_definition/1),
      "agent_environment_variable_names" =>
        Repo.all(
          from variable in AgentEnvironmentVariable,
            where: variable.repository_id == ^repository.id,
            order_by: variable.name,
            select: variable.name
        )
    }

    Map.put(document, "digest", digest(document))
  end

  defp export_definition(definition) do
    %{
      "key" => definition.key,
      "name" => definition.name,
      "description" => definition.description,
      "version" =>
        definition.current_version &&
          definition.current_version
          |> Map.take(DefinitionVersion.content_fields())
          |> stringify(),
      "triggers" =>
        definition.triggers
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&(&1 |> Map.take(@trigger_fields) |> stringify()))
    }
  end

  @doc "SHA-256 of the canonical document without its digest."
  def digest(document) do
    document
    |> Map.delete("digest")
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map(fn {key, value} -> [key, canonical(value)] end)

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  @doc """
  Validates a peer's document as data: the digest matches, the repository is
  the one asked for, and every part has the expected shape.
  """
  def validate(document, %Repository{} = repository) do
    cond do
      not is_map(document) ->
        {:error, :invalid_settings}

      document["digest"] != digest(document) ->
        {:error, :settings_digest_mismatch}

      document["repository"] != Claims.key(repository) ->
        {:error, :settings_for_another_repository}

      not is_map(document["settings"]) ->
        {:error, :invalid_settings}

      not valid_automations?(document["automations"]) ->
        {:error, :invalid_automations}

      not valid_names?(document["agent_environment_variable_names"]) ->
        {:error, :invalid_variable_names}

      true ->
        validate_settings(document, repository)
    end
  end

  # Peer data is checked for shape before anything renders or imports it.
  defp valid_automations?(automations) when is_list(automations) do
    keys = Enum.map(automations, &(is_map(&1) && &1["key"]))

    length(keys) == length(Enum.uniq(keys)) and
      Enum.all?(automations, fn
        %{"key" => key, "name" => name} = automation ->
          is_binary(key) and key != "" and is_binary(name) and
            (is_nil(automation["description"]) or is_binary(automation["description"])) and
            (is_nil(automation["version"]) or is_map(automation["version"])) and
            is_list(automation["triggers"]) and Enum.all?(automation["triggers"], &is_map/1)

        _other ->
          false
      end)
  end

  defp valid_automations?(_automations), do: false

  defp valid_names?(names) when is_list(names),
    do:
      Enum.all?(names, &(is_binary(&1) and &1 != "")) and
        length(names) == length(Enum.uniq(names))

  defp valid_names?(_names), do: false

  defp validate_settings(document, repository) do
    changeset = Repository.changeset(repository, settings_attrs(document))
    if changeset.valid?, do: :ok, else: {:error, {:invalid_settings, changeset.errors}}
  end

  defp settings_attrs(document) do
    for field <- @transferred,
        Map.has_key?(document["settings"], Atom.to_string(field)),
        into: %{},
        do: {field, document["settings"][Atom.to_string(field)]}
  end

  @doc """
  What a claim would change: settings whose value differs, automations to
  update or create, and the variable names the target lacks.
  """
  def diff(document, %Repository{} = repository) do
    present =
      Repo.all(
        from variable in AgentEnvironmentVariable,
          where: variable.repository_id == ^repository.id,
          select: variable.name
      )

    keys =
      Repo.all(
        from definition in Definition,
          where: definition.repository_id == ^repository.id,
          select: definition.key
      )

    %{
      settings:
        document
        |> settings_attrs()
        |> Enum.sort()
        |> Enum.flat_map(fn {field, incoming} ->
          current = Map.fetch!(repository, field)

          if normalize(current) == normalize(incoming),
            do: [],
            else: [%{field: field, current: current, incoming: incoming}]
        end),
      automations:
        Enum.map(document["automations"], fn automation ->
          %{
            key: automation["key"],
            name: automation["name"],
            action: if(automation["key"] in keys, do: "update", else: "create"),
            triggers: length(List.wrap(automation["triggers"]))
          }
        end),
      variables_to_enter: Enum.sort(document["agent_environment_variable_names"] -- present),
      variables: Enum.sort(document["agent_environment_variable_names"])
    }
  end

  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()

  @doc """
  Applies a validated document to the target's repository inside the claim's
  transaction, and records the import. Returns `:ok` or `{:error, reason}`;
  the caller rolls the claim back on an error, so a malformed peer document
  changes nothing.
  """
  def import(document, %Repository{} = repository, %{actor: actor, source: source, checks: checks}) do
    with :ok <- validate(document, repository),
         {:ok, _repository} <-
           repository |> Repository.changeset(settings_attrs(document)) |> Repo.update(),
         :ok <- pause_all(repository),
         :ok <- import_definitions(repository, document["automations"], actor) do
      %AuditEvent{}
      |> AuditEvent.changeset(%{
        actor: actor,
        action: "repository.settings_imported",
        target_type: "repository",
        target_id: repository.id,
        details: %{
          "repository" => document["repository"],
          "source" => source,
          "settings_digest" => document["digest"],
          "automations" => Enum.map(document["automations"], & &1["key"]),
          "agent_environment_variable_names" => document["agent_environment_variable_names"],
          "peer_checks" => checks
        }
      })
      |> Repo.insert!()

      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:invalid_settings, changeset.errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every automation of the repository is paused, imported or not, so nothing
  # runs on the new home before a maintainer reviews it.
  defp pause_all(repository) do
    definition_ids =
      from(definition in Definition,
        where: definition.repository_id == ^repository.id,
        select: definition.id
      )

    Repo.update_all(
      from(definition in Definition, where: definition.id in subquery(definition_ids)),
      set: [enabled: false]
    )

    Repo.update_all(
      from(trigger in Trigger,
        where: trigger.automation_definition_id in subquery(definition_ids)
      ),
      set: [enabled: false]
    )

    :ok
  end

  defp import_definitions(repository, automations, actor) do
    Enum.reduce_while(automations, :ok, fn automation, :ok ->
      case import_definition(repository, automation, actor) do
        :ok -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:error, {:invalid_automation, automation["key"]}}}
      end
    end)
  end

  defp import_definition(repository, %{"key" => key} = automation, actor) when is_binary(key) do
    with {:ok, definition} <- target_definition(repository, automation),
         {:ok, version} <- import_version(definition, automation["version"], actor),
         {:ok, definition} <-
           definition
           |> Definition.changeset(%{
             name: automation["name"],
             description: automation["description"],
             enabled: false,
             current_version_id: (version && version.id) || definition.current_version_id
           })
           |> Repo.update() do
      Repo.delete_all(
        from trigger in Trigger, where: trigger.automation_definition_id == ^definition.id
      )

      import_triggers(definition, List.wrap(automation["triggers"]))
    end
  end

  defp import_definition(_repository, _automation, _actor), do: {:error, :invalid_automation}

  defp target_definition(repository, automation) do
    case Repo.get_by(Definition, repository_id: repository.id, key: automation["key"]) do
      nil ->
        %Definition{}
        |> Definition.changeset(%{
          repository_id: repository.id,
          key: automation["key"],
          name: automation["name"],
          description: automation["description"],
          enabled: false
        })
        |> Repo.insert()

      definition ->
        {:ok, definition}
    end
  end

  defp import_version(_definition, nil, _actor), do: {:ok, nil}

  defp import_version(definition, version, actor) when is_map(version) do
    latest =
      Repo.one(
        from version in DefinitionVersion,
          where: version.automation_definition_id == ^definition.id,
          select: max(version.version)
      ) || 0

    %DefinitionVersion{}
    |> DefinitionVersion.changeset(
      version
      |> Map.take(Enum.map(DefinitionVersion.content_fields(), &Atom.to_string/1))
      |> Map.merge(%{
        "automation_definition_id" => definition.id,
        "version" => latest + 1,
        "created_by" => actor
      })
    )
    |> Repo.insert()
  end

  defp import_version(_definition, _version, _actor), do: {:error, :invalid_version}

  defp import_triggers(definition, triggers) do
    Enum.reduce_while(triggers, :ok, fn trigger, :ok ->
      result =
        if is_map(trigger) do
          %Trigger{}
          |> Trigger.changeset(
            trigger
            |> Map.take(Enum.map(@trigger_fields, &Atom.to_string/1))
            |> Map.merge(%{"automation_definition_id" => definition.id, "enabled" => false})
          )
          |> Repo.insert()
        else
          {:error, :invalid_trigger}
        end

      case result do
        {:ok, _trigger} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
