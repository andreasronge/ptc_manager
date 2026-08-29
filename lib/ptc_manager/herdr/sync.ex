defmodule PtcManager.Herdr.Sync do
  @moduledoc "Reconciles a read-only Herdr agent snapshot into durable worker activity."

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentRun, Worker}
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

    case client.list_agents() do
      {:ok, agents} when is_list(agents) -> persist_snapshot(session, agents, stale_after_ms)
      {:error, reason} -> mark_degraded(session, reason, stale_after_ms)
      other -> mark_degraded(session, {:unexpected_client_result, other}, stale_after_ms)
    end
  end

  defp persist_snapshot(session, remote_agents, stale_after_ms) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        worker = upsert_worker(session, "online", now)
        normalized = Enum.map(remote_agents, &normalize_agent(&1, session, now))

        existing_runs =
          AgentRun
          |> where([run], run.worker_id == ^worker.id and not is_nil(run.external_key))
          |> order_by([run], desc: run.inserted_at, desc: run.id)
          |> Repo.all()
          |> Enum.reduce(%{}, &Map.put_new(&2, &1.external_key, &1))

        observed_keys = MapSet.new(normalized, & &1.external_key)

        Enum.each(normalized, fn attrs ->
          upsert_agent_run(worker, Map.get(existing_runs, attrs.external_key), attrs)
        end)

        lost_count = mark_missing_runs_lost(existing_runs, observed_keys, now)

        %{worker: worker, agent_count: length(normalized), lost_count: lost_count}
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
      herdr_session: session
    }
  end

  defp upsert_agent_run(worker, nil, attrs) do
    insert_agent_run(worker, attrs)
  end

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

  defp mark_missing_runs_lost(existing_runs, observed_keys, now) do
    missing_runs =
      existing_runs
      |> Map.values()
      |> Enum.reject(
        &(&1.state in @terminal_states or MapSet.member?(observed_keys, &1.external_key))
      )

    Enum.each(missing_runs, fn run ->
      run
      |> AgentRun.changeset(%{
        state: "lost",
        status_text: "No longer present in the latest Herdr snapshot.",
        last_heartbeat_at: now,
        ended_at: now
      })
      |> Repo.update!()
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
        lost_count = mark_stale_runs_lost(worker, now, stale_after_ms)
        %{worker: worker, lost_count: lost_count}
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

    Enum.each(stale_runs, fn run ->
      run
      |> AgentRun.changeset(%{
        state: "lost",
        status_text: "Herdr could not confirm this agent after the heartbeat deadline.",
        ended_at: now
      })
      |> Repo.update!()
    end)

    length(stale_runs)
  end

  defp normalize_state(value) when value in ["queued", "starting", "working", "idle", "blocked"],
    do: value

  defp normalize_state(value) when value in ["done", "completed", "complete"], do: "done"
  defp normalize_state(value) when value in ["failed", "error"], do: "failed"
  defp normalize_state(value) when value in ["lost", "missing"], do: "lost"
  defp normalize_state(_value), do: "unknown"

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
