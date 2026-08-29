defmodule PtcManager.Herdr.Sync do
  @moduledoc "Reconciles a read-only Herdr agent snapshot into durable worker activity."

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentRun, AuditEvent, Job, Worker}
  alias PtcManager.Repo

  @terminal_states ~w(done failed lost)

  def sync(opts \\ []) do
    client = Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :herdr_client))

    session =
      Keyword.get(opts, :session, Application.get_env(:ptc_manager, :herdr_session, "default"))

    stale_after_ms =
      Keyword.get(
        opts,
        :stale_after_ms,
        Application.get_env(:ptc_manager, :herdr_stale_after_ms, 60_000)
      )

    reconcile_after_ms =
      Keyword.get(
        opts,
        :reconcile_after_ms,
        Application.get_env(:ptc_manager, :dispatch_reconcile_after_ms, 60_000)
      )

    case client.list_agents() do
      {:ok, agents} when is_list(agents) ->
        persist_snapshot(session, agents, stale_after_ms, reconcile_after_ms)

      {:error, reason} ->
        mark_degraded(session, reason, stale_after_ms)

      other ->
        mark_degraded(session, {:unexpected_client_result, other}, stale_after_ms)
    end
  end

  defp persist_snapshot(session, remote_agents, stale_after_ms, reconcile_after_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        worker = upsert_worker(session, "online", now)

        normalized =
          Enum.map(remote_agents, fn agent ->
            agent
            |> normalize_agent(session, now)
            |> maybe_attach_managed_attempt(worker.worker_key)
          end)

        existing_runs =
          AgentRun
          |> where([run], run.worker_id == ^worker.id and not is_nil(run.external_key))
          |> order_by([run], desc: run.inserted_at, desc: run.id)
          |> Repo.all()
          |> Enum.reduce(%{}, &Map.put_new(&2, &1.external_key, &1))

        observed_keys = MapSet.new(normalized, & &1.external_key)

        observed_run_ids =
          Enum.map(normalized, fn attrs ->
            existing_run = attrs[:managed_run] || Map.get(existing_runs, attrs.external_key)
            run = upsert_agent_run(worker, existing_run, attrs)
            reconcile_job(run, attrs.state, now)
            run.id
          end)
          |> MapSet.new()

        lost_count = mark_missing_runs_lost(existing_runs, observed_keys, observed_run_ids, now)

        absent_count =
          resolve_absent_reconciling_jobs(worker, normalized, now, reconcile_after_ms)

        %{
          worker: worker,
          agent_count: length(normalized),
          lost_count: lost_count,
          absent_count: absent_count
        }
      end)

    case result do
      {:ok, summary} ->
        Operations.notify_changed(__MODULE__)
        {:ok, summary}

      {:error, reason} ->
        mark_degraded(session, reason, stale_after_ms)
    end
  rescue
    error -> mark_degraded(session, error, stale_after_ms)
  end

  defp normalize_agent(agent, session, now) when is_map(agent) do
    state = normalize_state(value(agent, ["agent_status", "status", "state"]))
    pane = value(agent, ["pane_id", "pane", "herdr_pane"])
    native_session = nested_value(agent, ["agent_session", "value"])

    external_key =
      native_session || pane || value(agent, ["id", "agent_id"]) ||
        digest(Jason.encode!(agent))

    name = value(agent, ["display_agent", "agent", "name"]) || "Herdr agent"

    %{
      external_key: "#{session}:#{external_key}",
      role: infer_role(name),
      state: state,
      status_text: value(agent, ["status_text", "task", "description"]) || name,
      started_at: parse_datetime(value(agent, ["started_at", "created_at"])) || now,
      last_heartbeat_at: now,
      ended_at: if(state in @terminal_states, do: now),
      herdr_workspace: value(agent, ["workspace_id", "workspace"]),
      herdr_pane: pane,
      herdr_session: session,
      agent_name: value(agent, ["name", "agent_name"])
    }
  end

  defp upsert_agent_run(worker, nil, attrs) do
    insert_agent_run(worker, attrs)
  end

  defp upsert_agent_run(
         _worker,
         %AgentRun{job_id: job_id, state: previous_state} = run,
         %{state: state}
       )
       when not is_nil(job_id) and previous_state in @terminal_states and
              state not in @terminal_states,
       do: run

  defp upsert_agent_run(
         _worker,
         %AgentRun{state: "lost"} = run,
         %{state: state} = attrs
       )
       when state in ["done", "failed"] do
    attrs =
      attrs
      |> Map.put(:started_at, run.started_at)
      |> Map.put(:ended_at, run.ended_at)

    run |> AgentRun.changeset(attrs) |> Repo.update!()
  end

  defp upsert_agent_run(
         _worker,
         %AgentRun{state: previous_state} = run,
         %{state: state}
       )
       when previous_state in @terminal_states and state in @terminal_states,
       do: run

  defp upsert_agent_run(
         worker,
         %AgentRun{state: previous_state},
         %{state: state} = attrs
       )
       when previous_state in @terminal_states and state not in @terminal_states do
    insert_agent_run(worker, attrs)
  end

  defp upsert_agent_run(_worker, %AgentRun{} = run, attrs) do
    attrs = Map.put(attrs, :started_at, run.started_at)
    run |> AgentRun.changeset(attrs) |> Repo.update!()
  end

  defp insert_agent_run(worker, attrs) do
    %AgentRun{}
    |> AgentRun.changeset(Map.put(attrs, :worker_id, worker.id))
    |> Repo.insert!()
  end

  defp mark_missing_runs_lost(existing_runs, observed_keys, observed_run_ids, now) do
    missing_runs =
      existing_runs
      |> Map.values()
      |> Enum.reject(
        &(&1.state in @terminal_states or MapSet.member?(observed_keys, &1.external_key) or
            MapSet.member?(observed_run_ids, &1.id))
      )

    Enum.each(missing_runs, fn run ->
      lost =
        run
        |> AgentRun.changeset(%{
          state: "lost",
          status_text: "No longer present in the latest Herdr snapshot.",
          last_heartbeat_at: now,
          ended_at: now
        })
        |> Repo.update!()

      reconcile_job(lost, "lost", now)
    end)

    length(missing_runs)
  end

  defp upsert_worker(session, status, heartbeat_at) do
    key = "herdr:#{session}"

    attrs = %{
      worker_key: key,
      name: "Herdr #{session}",
      status: status,
      capabilities: %{"herdr" => true}
    }

    attrs = if heartbeat_at, do: Map.put(attrs, :last_heartbeat_at, heartbeat_at), else: attrs

    case Repo.get_by(Worker, worker_key: key) do
      nil -> %Worker{} |> Worker.changeset(attrs) |> Repo.insert!()
      worker -> worker |> Worker.changeset(attrs) |> Repo.update!()
    end
  end

  defp mark_degraded(session, reason, stale_after_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        worker = upsert_worker(session, "degraded", nil)
        {lost_count, uncertain_count} = mark_stale_runs_lost(worker, now, stale_after_ms)
        %{worker: worker, lost_count: lost_count, uncertain_count: uncertain_count}
      end)

    case result do
      {:ok, summary} ->
        Operations.notify_changed(__MODULE__)
        {:error, {reason, summary}}

      {:error, _failure} ->
        {:error, reason}
    end
  rescue
    _error -> {:error, reason}
  end

  defp mark_stale_runs_lost(worker, now, stale_after_ms) do
    active_runs =
      AgentRun
      |> where([run], run.worker_id == ^worker.id and run.state not in ^@terminal_states)
      |> Repo.all()

    stale_runs =
      Enum.filter(active_runs, fn run ->
        DateTime.diff(now, run.last_heartbeat_at, :millisecond) >= stale_after_ms
      end)

    Enum.reduce(stale_runs, {0, 0}, fn run, {lost_count, uncertain_count} ->
      if run.job_id do
        mark_managed_run_uncertain(run, now)
        {lost_count, uncertain_count + 1}
      else
        lost =
          run
          |> AgentRun.changeset(%{
            state: "lost",
            status_text: "Herdr could not confirm this agent after the heartbeat deadline.",
            ended_at: now
          })
          |> Repo.update!()

        reconcile_job(lost, "lost", now)
        {lost_count + 1, uncertain_count}
      end
    end)
  end

  defp normalize_state(value) when value in ["queued", "starting", "working", "idle", "blocked"],
    do: value

  defp normalize_state(value) when value in ["done", "completed", "complete"], do: "done"
  defp normalize_state(value) when value in ["failed", "error"], do: "failed"
  defp normalize_state(value) when value in ["lost", "missing"], do: "lost"
  defp normalize_state(_value), do: "unknown"

  defp reconcile_job(%AgentRun{job_id: nil}, _agent_state, _now), do: :ok

  defp reconcile_job(
         %AgentRun{state: run_state} = run,
         agent_state,
         now
       )
       when run_state in @terminal_states and agent_state not in @terminal_states do
    case owned_job(run) do
      %Job{fencing_token: token, state: state} = job
      when token == run.fencing_token and
             state in ~w(starting working idle blocked reconciling awaiting_reconciliation) ->
        job
        |> Job.changeset(%{
          state: "reconciling",
          lease_expires_at: nil,
          reconciling_at: now,
          absence_observed_at: nil,
          last_error: "A terminal managed agent identity became active again."
        })
        |> Repo.update!()

      _job ->
        :ok
    end
  end

  defp reconcile_job(%AgentRun{} = run, agent_state, now) do
    case owned_job(run) do
      %Job{fencing_token: token, state: state} = job
      when token == run.fencing_token and
             state in ~w(starting working idle blocked reconciling awaiting_reconciliation) ->
        update_job_from_agent(job, agent_state, now)

      _job ->
        :ok
    end
  end

  defp update_job_from_agent(job, agent_state, now) do
    state = job_state(agent_state, job.state)

    attrs =
      cond do
        state in ~w(failed lost) ->
          %{
            state: state,
            ended_at: now,
            lease_expires_at: nil,
            reconciling_at: nil,
            absence_observed_at: nil
          }

        state == "awaiting_reconciliation" ->
          %{
            state: state,
            lease_expires_at: nil,
            reconciling_at: now,
            absence_observed_at: nil
          }

        true ->
          lease_ms = Application.get_env(:ptc_manager, :dispatch_lease_ms, 1_800_000)

          %{
            state: state,
            lease_expires_at: DateTime.add(now, lease_ms, :millisecond),
            reconciling_at: nil,
            absence_observed_at: nil
          }
      end

    job |> Job.changeset(attrs) |> Repo.update!()
    :ok
  end

  defp job_state("working", _current), do: "working"
  defp job_state("blocked", _current), do: "blocked"
  defp job_state("idle", _current), do: "idle"
  defp job_state("done", _current), do: "awaiting_reconciliation"
  defp job_state("failed", _current), do: "failed"
  defp job_state("lost", _current), do: "lost"
  defp job_state(_state, current), do: current

  defp maybe_attach_managed_attempt(%{agent_name: name} = attrs, worker_key)
       when is_binary(name) do
    with [job_id, fencing_token] <-
           Regex.run(~r/^impl_j(\d+)_f(\d+)$/, name, capture: :all_but_first),
         {job_id, ""} <- Integer.parse(job_id),
         {fencing_token, ""} <- Integer.parse(fencing_token),
         %Job{fencing_token: ^fencing_token, state: state, lease_owner: ^worker_key} = job <-
           Repo.get(Job, job_id),
         true <- state in ~w(starting working idle blocked reconciling awaiting_reconciliation) do
      managed_run = Repo.get_by(AgentRun, job_id: job.id, fencing_token: fencing_token)

      attrs
      |> Map.put(:job_id, job.id)
      |> Map.put(:fencing_token, fencing_token)
      |> Map.put(:managed_run, managed_run)
    else
      _ -> attrs
    end
  end

  defp maybe_attach_managed_attempt(attrs, _worker_key), do: attrs

  defp mark_managed_run_uncertain(run, now) do
    run
    |> AgentRun.changeset(%{
      state: "unknown",
      status_text: "Herdr transport is unavailable; this managed agent may still be running."
    })
    |> Repo.update!()

    case owned_job(run) do
      %Job{fencing_token: token, state: state} = job
      when token == run.fencing_token and state in ~w(starting working idle blocked reconciling) ->
        job
        |> Job.changeset(%{
          state: "reconciling",
          lease_expires_at: nil,
          reconciling_at: job.reconciling_at || now,
          absence_observed_at: nil,
          last_error: "Herdr transport is unavailable; remote activity must be reconciled."
        })
        |> Repo.update!()

      _job ->
        :ok
    end
  end

  defp resolve_absent_reconciling_jobs(worker, normalized, now, reconcile_after_ms) do
    observed_names = MapSet.new(normalized, & &1.agent_name)

    Job
    |> where(
      [job],
      job.state == "reconciling" and job.lease_owner == ^worker.worker_key
    )
    |> Repo.all()
    |> Enum.count(fn job ->
      attempt_name = "impl_j#{job.id}_f#{job.fencing_token}"

      old_enough =
        job.reconciling_at &&
          DateTime.diff(now, job.reconciling_at, :millisecond) >= reconcile_after_ms

      cond do
        !old_enough || MapSet.member?(observed_names, attempt_name) ->
          false

        job.absence_observed_at ->
          fail_absent_attempt(job, now)

        true ->
          record_absence_observation(job, now)
          false
      end
    end)
  end

  defp record_absence_observation(job, now) do
    {updated, _rows} =
      Job
      |> where(
        [candidate],
        candidate.id == ^job.id and candidate.state == "reconciling" and
          candidate.fencing_token == ^job.fencing_token and
          is_nil(candidate.absence_observed_at)
      )
      |> Repo.update_all(set: [absence_observed_at: now, updated_at: now])

    if updated == 1 do
      insert_reconciliation_audit!(job, "job.agent_absence_observed")
    end
  end

  defp fail_absent_attempt(job, now) do
    {updated, _rows} =
      Job
      |> where(
        [candidate],
        candidate.id == ^job.id and candidate.state == "reconciling" and
          candidate.fencing_token == ^job.fencing_token and
          candidate.absence_observed_at == ^job.absence_observed_at
      )
      |> Repo.update_all(
        set: [
          state: "failed",
          ended_at: now,
          last_error: "Herdr confirmed that no managed agent exists for this attempt.",
          updated_at: now
        ]
      )

    if updated == 1 do
      insert_reconciliation_audit!(job, "job.absent_agent_confirmed")

      true
    else
      false
    end
  end

  defp insert_reconciliation_audit!(job, action) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: "worker:#{job.lease_owner}",
      action: action,
      target_type: "job",
      target_id: job.id,
      details: %{"fencing_token" => job.fencing_token}
    })
    |> Repo.insert!()
  end

  defp owned_job(%AgentRun{} = run) do
    with %Job{} = job <- Repo.get(Job, run.job_id),
         %Worker{worker_key: worker_key} <- Repo.get(Worker, run.worker_id),
         true <- job.lease_owner == worker_key do
      job
    else
      _ -> nil
    end
  end

  defp infer_role(name) do
    normalized = name |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, "manager") -> "manager"
      String.contains?(normalized, "review") -> "reviewer"
      true -> "implementer"
    end
  end

  defp value(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  defp nested_value(map, [first, second]) do
    case Map.get(map, first) do
      nested when is_map(nested) -> Map.get(nested, second)
      _ -> nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
