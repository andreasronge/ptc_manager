defmodule PtcManager.Automations do
  @moduledoc "Persisted, versioned automation configuration and invocation snapshots."

  import Ecto.Query

  alias Ecto.Multi

  alias PtcManager.Automations.{
    Defaults,
    Definition,
    DefinitionVersion,
    Invocation,
    Schedule,
    Trigger
  }

  alias PtcManager.Operations.{AgentAction, Repository}
  alias PtcManager.Repo

  @invocation_preloads [
    :repository,
    :automation_trigger,
    automation_definition_version: :automation_definition
  ]

  def list_definitions(%Repository{id: repository_id}) do
    Definition
    |> where([definition], definition.repository_id == ^repository_id)
    |> where([definition], is_nil(definition.archived_at))
    |> order_by([definition], asc: definition.name, asc: definition.id)
    |> preload([:repository, :current_version, :versions, :triggers])
    |> Repo.all()
  end

  def get_definition!(id) when is_integer(id) do
    Definition
    |> where([definition], is_nil(definition.archived_at))
    |> preload([:repository, :current_version, :versions, :triggers])
    |> Repo.get!(id)
  end

  @doc "Whether PtcManager ships this definition, as opposed to a maintainer-created one."
  def built_in?(%Definition{} = definition),
    do: Defaults.get(definition.repository, definition.key) != nil

  @doc """
  Whether the bootstrap would recreate this trigger if it were deleted.

  Built-in schedules carry a marker in their configuration; other built-in
  triggers are recognised by their type and surface, as the bootstrap does.
  """
  def default_trigger?(%Definition{} = definition, %Trigger{} = trigger) do
    definition.key
    |> Defaults.triggers(definition.repository)
    |> Enum.any?(&matches_default?(&1, trigger))
  end

  @doc "A plain-language summary of the enabled triggers, such as \"Every day at 03:00 · Run now\"."
  def trigger_summary(%Definition{triggers: triggers}) do
    triggers
    |> Enum.filter(& &1.enabled)
    |> Enum.sort_by(&{trigger_order(&1.trigger_type), &1.id})
    |> Enum.map(&trigger_description/1)
    |> case do
      [] -> "Paused"
      parts -> Enum.join(parts, " · ")
    end
  end

  def trigger_description(%Trigger{trigger_type: "schedule"} = trigger),
    do: Schedule.describe(trigger.cron_expression)

  def trigger_description(%Trigger{trigger_type: "manual"}), do: "Run now"

  def trigger_description(%Trigger{trigger_type: "contextual"} = trigger),
    do: "Button on #{surface_label(trigger.surface)}"

  def surface_label("planning_issue"), do: "Planning issues"
  def surface_label("delivery_pr"), do: "Delivery pull requests"
  def surface_label(surface), do: surface

  @doc "The surface a contextual button belongs on for a version's target type."
  def surface_for_target("issue"), do: "planning_issue"
  def surface_for_target("pull_request"), do: "delivery_pr"
  def surface_for_target(_target_type), do: nil

  @doc "Derives an unused internal key for a repository from a human-readable name."
  def slug_key(%Repository{id: repository_id}, name) when is_binary(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 60)
      |> String.trim_trailing("_")

    base =
      if base =~ ~r/\A[a-z]/, do: base, else: String.trim_trailing("automation_" <> base, "_")

    available_key(repository_id, base)
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
         prompt: compose_prompt(version.prompt, attrs[:prompt])
       })}
    end
  end

  def resolved_instructions(%DefinitionVersion{} = version, legacy) do
    [trimmed(version.prompt), trimmed(legacy)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      instructions -> instructions
    end
  end

  def ensure_defaults(%Repository{} = repository) do
    Enum.reduce_while(Defaults.all(repository), :ok, fn spec, :ok ->
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

  def delete_trigger(%Trigger{} = trigger), do: Repo.delete(trigger)

  def list_invocations(%Repository{id: repository_id}, limit_count \\ 100) do
    Invocation
    |> where([invocation], invocation.repository_id == ^repository_id)
    |> order_by([invocation], desc: invocation.requested_at, desc: invocation.id)
    |> limit(^limit_count)
    |> preload(^@invocation_preloads)
    |> Repo.all()
  end

  def list_all_invocations(limit_count \\ 100) do
    Invocation
    |> order_by([invocation], desc: invocation.requested_at, desc: invocation.id)
    |> limit(^limit_count)
    |> preload(^@invocation_preloads)
    |> Repo.all()
  end

  @doc "Runs of one automation across all of its versions, newest first."
  def list_invocations_for_definition(%Definition{id: definition_id}, opts \\ []) do
    limit_count = Keyword.get(opts, :limit, 20)
    offset_count = Keyword.get(opts, :offset, 0)

    Invocation
    |> join(:inner, [invocation], version in assoc(invocation, :automation_definition_version))
    |> where([invocation, version], version.automation_definition_id == ^definition_id)
    |> order_by([invocation], desc: invocation.requested_at, desc: invocation.id)
    |> limit(^limit_count)
    |> offset(^offset_count)
    |> preload(^@invocation_preloads)
    |> Repo.all()
  end

  @doc "The newest run of every automation in a repository, keyed by definition id."
  def latest_invocation_by_definition(%Repository{id: repository_id}) do
    ranked =
      from invocation in Invocation,
        join: version in assoc(invocation, :automation_definition_version),
        where: invocation.repository_id == ^repository_id,
        select: %{
          id: invocation.id,
          definition_id: version.automation_definition_id,
          rank:
            row_number()
            |> over(
              partition_by: version.automation_definition_id,
              order_by: [desc: invocation.requested_at, desc: invocation.id]
            )
        }

    from(invocation in Invocation,
      join: newest in subquery(ranked),
      on: newest.id == invocation.id,
      where: newest.rank == 1,
      select: {newest.definition_id, invocation}
    )
    |> Repo.all()
    |> Map.new()
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
      %{key: "review_issue", label: "Review issue", description: "Challenge issue readiness"},
      %{
        key: "structure_collection",
        label: "Structure collection",
        description: "Turn a plan into ordered sub-issues"
      }
    ]
  end

  def contextual_actions(nil, "delivery_pr") do
    [
      %{key: "repair_pr", label: "Fix", description: "Repair the pull request"},
      %{
        key: "repair_and_merge_pr",
        label: "Fix and merge",
        description: "Repair and merge the pull request"
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
          completed_invocation_attrs(action)

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

  defp completed_invocation_attrs(%AgentAction{action_key: "daily_digest"} = action) do
    case Repo.get(PtcManager.DailyDigests.DailyDigest, action.target_id) do
      %{
        agent_action_id: id,
        repository_id: repository_id,
        published_at: %DateTime{},
        markdown: markdown
      } = digest
      when id == action.id and repository_id == action.repository_id and is_binary(markdown) ->
        %{
          state: if(digest.change_count == 0, do: "no_changes", else: "succeeded"),
          result_status: if(digest.change_count == 0, do: "no-changes", else: "published"),
          result_markdown: markdown,
          ended_at: action.ended_at
        }

      _ ->
        %{
          state: "failed",
          result_status: "invalid_report",
          result_markdown: nil,
          last_error: "daily_digest_not_published",
          ended_at: action.ended_at
        }
    end
  end

  defp completed_invocation_attrs(action) do
    result = decode_result(action.result_summary)

    %{
      state: if(result["outcome"] == "no-changes", do: "no_changes", else: "succeeded"),
      result_status: result["outcome"] || "completed",
      result_markdown: result["markdown"] || result["private_summary"] || action.result_summary,
      ended_at: action.ended_at
    }
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
        enabled: Map.get(spec, :enabled, true)
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
    existing =
      Trigger
      |> where([trigger], trigger.automation_definition_id == ^definition.id)
      |> Repo.all()

    Defaults.triggers(spec.key, repository)
    |> Enum.reject(fn attrs -> Enum.any?(existing, &matches_default?(attrs, &1)) end)
    |> Enum.reduce_while(:ok, fn attrs, :ok ->
      %Trigger{}
      |> Trigger.changeset(
        attrs
        |> Map.put(:automation_definition_id, definition.id)
        |> Map.put(:configuration, %{"built_in" => true})
        |> maybe_put_next_run()
      )
      |> Repo.insert()
      |> case do
        {:ok, _trigger} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      :ok ->
        {:ok, Repo.preload(definition, [:current_version, :versions, :triggers], force: true)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # A definition may hold several schedules, so a built-in schedule is known by
  # its marker rather than by its surface. Other trigger types stay unique per
  # surface and are recognised the way they always were.
  defp matches_default?(%{trigger_type: "schedule"}, %Trigger{} = trigger),
    do: trigger.trigger_type == "schedule" and built_in_trigger?(trigger)

  defp matches_default?(spec, %Trigger{} = trigger),
    do: spec.trigger_type == trigger.trigger_type and spec.surface == trigger.surface

  defp built_in_trigger?(%Trigger{configuration: configuration}),
    do: is_map(configuration) and configuration["built_in"] == true

  defp trigger_order("schedule"), do: 0
  defp trigger_order("manual"), do: 1
  defp trigger_order(_type), do: 2

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

    runtime =
      """
      <runtime_context action="#{definition.key}" repository="#{repository.github_owner}/#{repository.github_name}" default_branch="#{repository.default_branch}" invocation_marker="#{marker}" trigger_context='#{Jason.encode!(context)}' allowed_outcomes="completed,no-changes" />
      """

    compose_prompt(version.prompt, runtime)
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

  defp next_run(expression, time_zone, from),
    do: Schedule.next_run_at(expression, time_zone, from)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp decode_result(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> result
      _invalid -> %{}
    end
  end

  defp decode_result(_body), do: %{}

  def compose_prompt(user_prompt, runtime_context) do
    [trimmed(user_prompt), trimmed(runtime_context)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp trimmed(_value), do: nil

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
