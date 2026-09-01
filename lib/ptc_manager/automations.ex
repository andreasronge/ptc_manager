defmodule PtcManager.Automations do
  @moduledoc "Persisted, versioned automation configuration and invocation snapshots."

  import Ecto.Query

  alias Ecto.Multi
  alias PtcManager.Automations.{Defaults, Definition, DefinitionVersion, Invocation, Trigger}
  alias PtcManager.Operations.{AgentAction, Repository}
  alias PtcManager.Repo

  @compatibility_prompt "Use the code-owned target prompt builder for this compatibility definition."

  def list_definitions(%Repository{id: repository_id}) do
    Definition
    |> where([definition], definition.repository_id == ^repository_id)
    |> where([definition], is_nil(definition.archived_at))
    |> order_by([definition], asc: definition.name, asc: definition.id)
    |> preload([:repository, :current_version, :versions, :triggers])
    |> Repo.all()
  end

  def get_definition(%Repository{id: repository_id}, key) when is_binary(key) do
    Definition
    |> where([definition], definition.repository_id == ^repository_id and definition.key == ^key)
    |> preload([:repository, :current_version, :versions, :triggers])
    |> Repo.one()
  end

  def current_version(%Repository{} = repository, key) when is_binary(key) do
    with %Definition{
           enabled: true,
           archived_at: nil,
           current_version: %DefinitionVersion{} = version
         } <-
           get_definition(repository, key) do
      {:ok, version}
    else
      %Definition{enabled: false} -> {:error, :automation_disabled}
      %Definition{} -> {:error, :automation_version_missing}
      nil -> {:error, :automation_not_found}
    end
  end

  def snapshot_attrs(%Repository{} = repository, key, attrs)
      when is_binary(key) and is_map(attrs) do
    with :ok <- ensure_defaults(repository),
         {:ok, version} <- current_version(repository, key) do
      {:ok,
       Map.merge(attrs, %{
         automation_definition_version_id: version.id,
         prompt_version: version.version,
         prompt: append_version_prompt(attrs[:prompt], version.prompt)
       })}
    end
  end

  def resolved_instructions(%DefinitionVersion{} = version, legacy) do
    [legacy, custom_version_prompt(version.prompt)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      instructions -> instructions
    end
  end

  def ensure_defaults(%Repository{} = repository) do
    Enum.reduce_while(Defaults.all(), :ok, fn spec, :ok ->
      case ensure_default(repository, spec) do
        {:ok, _definition} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ensure_defaults_for_all do
    Repository
    |> order_by([repository], asc: repository.id)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn repository, :ok ->
      case ensure_defaults(repository) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {repository.id, reason}}}
      end
    end)
  end

  def create_version(%Definition{} = definition, attrs, actor)
      when is_map(attrs) and is_binary(actor) do
    Repo.transaction(fn ->
      locked = Definition |> where([item], item.id == ^definition.id) |> Repo.one!()
      latest = latest_version_number(locked.id)

      version =
        %DefinitionVersion{}
        |> DefinitionVersion.changeset(
          attrs
          |> Map.put(:automation_definition_id, locked.id)
          |> Map.put(:version, latest + 1)
          |> Map.put(:created_by, actor)
        )
        |> Repo.insert!()

      locked
      |> Definition.changeset(%{current_version_id: version.id})
      |> Repo.update!()

      Repo.preload(version, :automation_definition)
    end)
  end

  def create_definition(%Repository{} = repository, identity, version_attrs, actor)
      when is_map(identity) and is_map(version_attrs) and is_binary(actor) do
    Repo.transaction(fn ->
      definition =
        %Definition{}
        |> Definition.changeset(Map.merge(identity, %{repository_id: repository.id}))
        |> Repo.insert!()

      version =
        %DefinitionVersion{}
        |> DefinitionVersion.changeset(
          version_attrs
          |> Map.put(:automation_definition_id, definition.id)
          |> Map.put(:version, 1)
          |> Map.put(:created_by, actor)
        )
        |> Repo.insert!()

      definition
      |> Definition.changeset(%{current_version_id: version.id})
      |> Repo.update!()
      |> Repo.preload([:current_version, :versions, :triggers])
    end)
  end

  def create_trigger(%Definition{} = definition, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put(:automation_definition_id, definition.id)
      |> maybe_put_next_run()

    %Trigger{} |> Trigger.changeset(attrs) |> Repo.insert()
  end

  def update_trigger(%Trigger{} = trigger, attrs) when is_map(attrs) do
    attrs = maybe_put_next_run(Map.merge(Map.from_struct(trigger), attrs))
    trigger |> Trigger.changeset(attrs) |> Repo.update()
  end

  def list_invocations(%Repository{id: repository_id}, limit_count \\ 100) do
    Invocation
    |> where([invocation], invocation.repository_id == ^repository_id)
    |> order_by([invocation], desc: invocation.requested_at, desc: invocation.id)
    |> limit(^limit_count)
    |> preload([
      :repository,
      :automation_trigger,
      automation_definition_version: :automation_definition
    ])
    |> Repo.all()
  end

  def list_all_invocations(limit_count \\ 100) do
    Invocation
    |> order_by([invocation], desc: invocation.requested_at, desc: invocation.id)
    |> limit(^limit_count)
    |> preload([
      :repository,
      :automation_trigger,
      automation_definition_version: :automation_definition
    ])
    |> Repo.all()
  end

  def get_trigger!(id) do
    Trigger
    |> preload(automation_definition: [:repository, :current_version])
    |> Repo.get!(id)
  end

  def contextual_actions(repository_id, surface)
      when is_integer(repository_id) and surface in ["planning_issue", "delivery_pr"] do
    Trigger
    |> join(:inner, [trigger], definition in assoc(trigger, :automation_definition))
    |> where(
      [trigger, definition],
      definition.repository_id == ^repository_id and definition.enabled == true and
        is_nil(definition.archived_at) and trigger.trigger_type == "contextual" and
        trigger.surface == ^surface and trigger.enabled == true
    )
    |> order_by([trigger, definition], asc: definition.name, asc: definition.id)
    |> preload([trigger, definition], automation_definition: definition)
    |> Repo.all()
    |> Enum.map(fn trigger ->
      %{
        key: trigger.automation_definition.key,
        label: trigger.label,
        description: trigger.automation_definition.description
      }
    end)
  end

  def contextual_actions(nil, "planning_issue") do
    [
      %{
        key: "prepare_issue",
        label: "Prepare issue",
        description: "Investigate and update GitHub"
      },
      %{key: "review_issue", label: "Review issue", description: "Challenge issue readiness"}
    ]
  end

  def contextual_actions(nil, "delivery_pr") do
    [
      %{key: "repair_pr", label: "Fix", description: "Repair the pull request"},
      %{
        key: "repair_and_merge_pr",
        label: "Fix and merge",
        description: "Repair and merge the pull request"
      },
      %{
        key: "prepare_merge_decision",
        label: "Prepare merge decision",
        description: "Create a private merge summary"
      }
    ]
  end

  def due_schedule_triggers(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    Trigger
    |> join(:inner, [trigger], definition in assoc(trigger, :automation_definition))
    |> where(
      [trigger, definition],
      trigger.trigger_type == "schedule" and trigger.enabled == true and
        definition.enabled == true and is_nil(definition.archived_at) and
        not is_nil(trigger.next_run_at) and trigger.next_run_at <= ^now
    )
    |> order_by([trigger], asc: trigger.next_run_at, asc: trigger.id)
    |> preload([trigger, definition],
      automation_definition: {definition, [:repository, :current_version]}
    )
    |> Repo.all()
  end

  def run_trigger(%Trigger{} = trigger, actor, opts \\ []) when is_binary(actor) do
    trigger = Repo.preload(trigger, automation_definition: [:repository, :current_version])
    definition = trigger.automation_definition
    version = definition.current_version
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    occurrence_key = Keyword.get(opts, :occurrence_key)
    context = Keyword.get(opts, :context, %{})

    cond do
      not trigger.enabled ->
        {:error, :trigger_disabled}

      not definition.enabled ->
        {:error, :automation_disabled}

      is_nil(version) ->
        {:error, :automation_version_missing}

      version.target_type != "repository" ->
        {:error, :exact_target_required}

      definition.key == "daily_digest" ->
        materialize_daily_digest(
          trigger,
          definition,
          version,
          actor,
          now,
          occurrence_key,
          context
        )

      true ->
        materialize_repository_invocation(
          trigger,
          definition,
          version,
          actor,
          now,
          occurrence_key,
          context
        )
    end
  end

  def advance_schedule(%Trigger{} = trigger, from) do
    with {:ok, next_run_at} <- next_run(trigger.cron_expression, trigger.time_zone, from) do
      trigger
      |> Trigger.changeset(%{next_run_at: next_run_at, last_enqueued_at: from})
      |> Repo.update()
    end
  end

  def reconcile_invocation(%AgentAction{id: action_id} = action) do
    attrs =
      case action.state do
        "queued" ->
          %{state: "queued"}

        "running" ->
          %{state: "running", started_at: action.started_at}

        "sync_pending" ->
          %{state: "synchronizing", started_at: action.started_at}

        "done" ->
          result = decode_result(action.result_summary)

          %{
            state: if(result["outcome"] == "no-changes", do: "no_changes", else: "succeeded"),
            result_status: result["outcome"] || "completed",
            result_markdown:
              result["markdown"] || result["private_summary"] || action.result_summary,
            ended_at: action.ended_at
          }

        "failed" ->
          %{state: "failed", last_error: action.last_error, ended_at: action.ended_at}
      end

    Invocation
    |> where([invocation], invocation.agent_action_id == ^action_id)
    |> Repo.update_all(
      set:
        Map.to_list(
          Map.put(attrs, :updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
        )
    )

    :ok
  end

  def record_invocation_runtime(%AgentAction{id: action_id} = action, kind, name) do
    source_sha = (action.target_snapshot || %{})["source_sha"]
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Invocation
    |> where([invocation], invocation.agent_action_id == ^action_id)
    |> Repo.update_all(
      set: [
        state: "running",
        source_sha: source_sha,
        selected_agent_kind: kind,
        selected_agent_name: name,
        started_at: action.started_at || now,
        updated_at: now
      ]
    )

    :ok
  end

  def link_agent_action_invocation(
        %Repository{} = repository,
        key,
        %AgentAction{} = action,
        actor
      ) do
    definition = get_definition(repository, key)
    trigger = Enum.find(definition.triggers, &(&1.trigger_type == "contextual"))

    %Invocation{}
    |> Invocation.changeset(%{
      repository_id: repository.id,
      automation_definition_version_id: action.automation_definition_version_id,
      automation_trigger_id: trigger && trigger.id,
      agent_action_id: action.id,
      trigger_type: "contextual",
      trigger_context: %{"target_type" => action.target_type, "target_id" => action.target_id},
      state: action.state,
      requested_by: actor,
      requested_at: action.requested_at
    })
    |> Repo.insert()
  end

  def link_job_invocation(%PtcManager.Operations.Job{} = job, actor) do
    %Invocation{}
    |> Invocation.changeset(%{
      repository_id: job.repository_id,
      automation_definition_version_id: job.automation_definition_version_id,
      job_id: job.id,
      trigger_type: "contextual",
      trigger_context: %{"target_type" => "issue", "target_id" => job.issue_id},
      state: job.state,
      requested_by: actor,
      requested_at: job.inserted_at
    })
    |> Repo.insert()
  end

  def update_identity(%Definition{} = definition, attrs) when is_map(attrs),
    do: definition |> Definition.changeset(attrs) |> Repo.update()

  def update_definition(%Definition{} = definition, identity_attrs, version_attrs, actor) do
    Repo.transaction(fn ->
      definition
      |> Definition.changeset(identity_attrs)
      |> Repo.update!()

      case create_version(definition, version_attrs, actor) do
        {:ok, version} -> version
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def duplicate_definition(%Definition{} = source, %Repository{} = target, actor) do
    source = Repo.preload(source, :current_version)
    version = source.current_version

    identity = %{
      key: available_key(target.id, source.key),
      name: source.name,
      description: source.description,
      enabled: false
    }

    attrs =
      version
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
        :operational_policy,
        :prompt,
        :configuration_snapshot
      ])

    create_definition(target, identity, attrs, actor)
  end

  defp ensure_default(repository, spec) do
    case Repo.get_by(Definition, repository_id: repository.id, key: spec.key) do
      nil ->
        insert_default(repository, spec)

      %Definition{current_version_id: nil} = definition ->
        insert_default_version(definition, spec)

      definition ->
        ensure_default_triggers(definition, repository, spec)
    end
  end

  defp insert_default(repository, spec) do
    Multi.new()
    |> Multi.insert(
      :definition,
      Definition.changeset(%Definition{}, %{
        repository_id: repository.id,
        key: spec.key,
        name: spec.name,
        description: spec.description,
        enabled: true
      })
    )
    |> Multi.insert(:version, fn %{definition: definition} ->
      DefinitionVersion.changeset(
        %DefinitionVersion{},
        version_attrs(definition.id, spec, 1, "system:built-in")
      )
    end)
    |> Multi.update(:current, fn %{definition: definition, version: version} ->
      Definition.changeset(definition, %{current_version_id: version.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{current: definition}} -> ensure_default_triggers(definition, repository, spec)
      {:error, _operation, changeset, _changes} -> {:error, changeset}
    end
  end

  defp insert_default_version(definition, spec) do
    result =
      Repo.transaction(fn ->
        version =
          %DefinitionVersion{}
          |> DefinitionVersion.changeset(version_attrs(definition.id, spec, 1, "system:built-in"))
          |> Repo.insert!()

        definition
        |> Definition.changeset(%{current_version_id: version.id})
        |> Repo.update!()
      end)

    case result do
      {:ok, updated} ->
        repository = Repo.get!(Repository, updated.repository_id)
        ensure_default_triggers(updated, repository, spec)

      error ->
        error
    end
  end

  defp ensure_default_triggers(definition, repository, spec) do
    Enum.each(Defaults.triggers(spec.key, repository), fn attrs ->
      case Repo.get_by(Trigger,
             automation_definition_id: definition.id,
             trigger_type: attrs.trigger_type,
             surface: attrs.surface
           ) do
        nil ->
          %Trigger{}
          |> Trigger.changeset(
            attrs
            |> Map.put(:automation_definition_id, definition.id)
            |> maybe_put_next_run()
          )
          |> Repo.insert!()

        _existing ->
          :ok
      end
    end)

    {:ok, Repo.preload(definition, [:current_version, :versions, :triggers], force: true)}
  end

  defp materialize_repository_invocation(
         trigger,
         definition,
         version,
         actor,
         now,
         occurrence_key,
         context
       ) do
    repository = definition.repository

    Repo.transaction(fn ->
      existing =
        if occurrence_key,
          do:
            Repo.get_by(Invocation,
              automation_trigger_id: trigger.id,
              occurrence_key: occurrence_key
            )

      if existing do
        existing
      else
        invocation =
          %Invocation{}
          |> Invocation.changeset(%{
            repository_id: repository.id,
            automation_definition_version_id: version.id,
            automation_trigger_id: trigger.id,
            trigger_type: trigger.trigger_type,
            trigger_context: context,
            occurrence_key: occurrence_key,
            state: "queued",
            requested_by: actor,
            requested_at: now
          })
          |> Repo.insert!()

        action_attrs = %{
          repository_id: repository.id,
          automation_definition_version_id: version.id,
          action_key: definition.key,
          target_type: "repository",
          target_id: repository.id,
          target_label: "#{repository.github_owner}/#{repository.github_name}",
          prompt_version: version.version,
          prompt: repository_prompt(repository, definition, version, invocation, context),
          actor: actor
        }

        action =
          case PtcManager.Operations.enqueue_agent_action(action_attrs) do
            {:ok, action} -> action
            {:error, reason} -> Repo.rollback(reason)
          end

        invocation
        |> Invocation.changeset(%{agent_action_id: action.id})
        |> Repo.update!()
      end
    end)
  rescue
    error in Ecto.ConstraintError -> {:error, error}
  end

  defp materialize_daily_digest(
         trigger,
         definition,
         version,
         actor,
         now,
         occurrence_key,
         context
       ) do
    repository = definition.repository

    with {:ok, window} <- PtcManager.DailyDigests.previous_day_window(now, trigger.time_zone),
         {:ok, digest} <- PtcManager.DailyDigests.enqueue(repository, window, actor: actor),
         %AgentAction{} = action <- digest.agent_action do
      attrs = %{
        repository_id: repository.id,
        automation_definition_version_id: version.id,
        automation_trigger_id: trigger.id,
        agent_action_id: action.id,
        trigger_type: trigger.trigger_type,
        trigger_context: context,
        occurrence_key: occurrence_key,
        state: action.state,
        requested_by: actor,
        requested_at: now
      }

      case Repo.get_by(Invocation,
             automation_trigger_id: trigger.id,
             occurrence_key: occurrence_key
           ) do
        nil -> %Invocation{} |> Invocation.changeset(attrs) |> Repo.insert()
        existing -> {:ok, existing}
      end
    end
  end

  defp repository_prompt(repository, definition, version, invocation, context) do
    marker = "ptc-manager-invocation:#{invocation.id}"

    """
    You are running the configured PtcManager automation #{definition.name}.

    Repository: #{repository.github_owner}/#{repository.github_name}
    Default branch: #{repository.default_branch}
    Stable invocation marker: #{marker}
    Trigger context: #{Jason.encode!(context)}

    #{version.operational_policy}

    #{version.prompt}

    Include the stable invocation marker in any GitHub issue you create or update. Return the required structured result with a plain-language private_summary, technical_evidence, evidence, github_changes, and created_issue_numbers. Use outcome "completed" when work was performed or "no-changes" when no GitHub change was needed.
    """
  end

  defp maybe_put_next_run(attrs) do
    if value(attrs, :trigger_type) == "schedule" and is_nil(value(attrs, :next_run_at)) do
      case next_run(value(attrs, :cron_expression), value(attrs, :time_zone), DateTime.utc_now()) do
        {:ok, next_run_at} -> Map.put(attrs, :next_run_at, next_run_at)
        _error -> attrs
      end
    else
      attrs
    end
  end

  defp next_run(expression, time_zone, from)
       when is_binary(expression) and is_binary(time_zone) do
    with {:ok, cron} <- Oban.Cron.Expression.parse(expression),
         {:ok, local} <- DateTime.shift_zone(from, time_zone, Tz.TimeZoneDatabase),
         %DateTime{} = next_local <- Oban.Cron.Expression.next_at(cron, local) do
      DateTime.shift_zone(next_local, "Etc/UTC", Tz.TimeZoneDatabase)
    end
  rescue
    _error -> {:error, :invalid_schedule}
  end

  defp next_run(_expression, _time_zone, _from), do: {:error, :invalid_schedule}
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp decode_result(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> result
      _invalid -> %{}
    end
  end

  defp decode_result(_body), do: %{}

  defp append_version_prompt(base, prompt) when is_binary(base) do
    case custom_version_prompt(prompt) do
      nil -> base
      instructions -> base <> "\n\nRepository-specific automation instructions:\n" <> instructions
    end
  end

  defp custom_version_prompt(prompt)
       when is_binary(prompt) and prompt != @compatibility_prompt do
    case String.trim(prompt) do
      "" -> nil
      value -> value
    end
  end

  defp custom_version_prompt(_prompt), do: nil

  defp available_key(repository_id, source_key, suffix \\ 1) do
    candidate = if suffix == 1, do: source_key, else: "#{source_key}_#{suffix}"

    if Repo.exists?(
         from definition in Definition,
           where: definition.repository_id == ^repository_id and definition.key == ^candidate
       ),
       do: available_key(repository_id, source_key, suffix + 1),
       else: candidate
  end

  defp version_attrs(definition_id, spec, version, actor) do
    spec
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
      :operational_policy,
      :prompt,
      :configuration_snapshot
    ])
    |> Map.merge(%{
      automation_definition_id: definition_id,
      version: version,
      created_by: actor
    })
  end

  defp latest_version_number(definition_id) do
    DefinitionVersion
    |> where([version], version.automation_definition_id == ^definition_id)
    |> select([version], max(version.version))
    |> Repo.one()
    |> Kernel.||(0)
  end
end
