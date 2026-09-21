defmodule PtcManager.Herdr.Sync do
  @moduledoc "Reconciles a read-only Herdr agent snapshot into durable worker activity."

  import Ecto.Query

  alias PtcManager.Clock
  alias PtcManager.DatabaseDiagnostics
  alias PtcManager.Gateway
  alias PtcManager.Herdr.StateRevision
  alias PtcManager.Operations
  alias PtcManager.RuntimeIncarnation

  alias PtcManager.Operations.{
    AgentRun,
    AuditEvent,
    Job,
    Worker,
    WorktreeAllocation
  }

  alias PtcManager.Repo
  alias PtcManager.RepoTransaction
  @shared_pane_states ~w(starting working idle blocked waiting unknown)
  @executing_pane_states ~w(working blocked)
  @terminal_states ~w(done failed lost)
  @active_agent_states ~w(queued starting working blocked)
  @touch_interval_ms 60_000
  @terminal_action_states ~w(done failed cancelled)
  @superseded_status "Superseded duplicate of the action-owned Herdr run."
  @recoverable_attention_job_states ~w(starting working idle blocked reconciling awaiting_reconciliation)
  @missing_retained_error "Herdr confirmed that the retained managed agent is no longer present."
  @absent_agent_error "Herdr confirmed that no managed agent exists for this attempt."

  def sync(opts \\ []) do
    clock = Keyword.get(opts, :clock, PtcManager.Clock.System)

    # This marker is compared with Ecto's database-write timestamps, so it must
    # use the same real wall-clock domain even when lease time is virtualized.
    snapshot_started_at = Clock.utc_now(PtcManager.Clock.System)
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

    case Gateway.call(client, :list_agents, []) do
      {:ok, snapshot} ->
        with {:ok, agents, identity} <- normalize_snapshot(snapshot) do
          persist_snapshot(
            session,
            agents,
            identity,
            stale_after_ms,
            reconcile_after_ms,
            snapshot_started_at,
            Clock.utc_now(PtcManager.Clock.System),
            Clock.utc_now(clock)
          )
        else
          {:error, reason} ->
            mark_degraded(
              session,
              reason,
              stale_after_ms,
              Clock.utc_now(PtcManager.Clock.System),
              Clock.utc_now(clock)
            )
        end

      {:error, reason} ->
        mark_degraded(
          session,
          reason,
          stale_after_ms,
          Clock.utc_now(PtcManager.Clock.System),
          Clock.utc_now(clock)
        )

      other ->
        mark_degraded(
          session,
          {:unexpected_client_result, other},
          stale_after_ms,
          Clock.utc_now(PtcManager.Clock.System),
          Clock.utc_now(clock)
        )
    end
  end

  defp persist_snapshot(
         session,
         remote_agents,
         identity,
         stale_after_ms,
         reconcile_after_ms,
         snapshot_started_at,
         agent_now,
         lease_now
       ) do
    result =
      persist_snapshot_attempt(
        session,
        remote_agents,
        identity,
        stale_after_ms,
        reconcile_after_ms,
        snapshot_started_at,
        agent_now,
        lease_now,
        1
      )

    case result do
      {:ok, summary} ->
        Operations.notify_changed(__MODULE__)
        {:ok, summary}

      {:error, reason} when reason in [:database_busy, :concurrent_state_change] ->
        {:error, reason}

      {:error, reason} ->
        mark_degraded(session, reason, stale_after_ms, agent_now, lease_now)
    end
  rescue
    # A busy database says nothing about Herdr: skip this cycle and let the
    # next snapshot try again instead of degrading the worker.
    error ->
      if RepoTransaction.busy?(error),
        do: {:error, :database_busy},
        else: mark_degraded(session, error, stale_after_ms, agent_now, lease_now)
  end

  defp persist_snapshot_attempt(
         session,
         remote_agents,
         identity,
         stale_after_ms,
         reconcile_after_ms,
         snapshot_started_at,
         agent_now,
         lease_now,
         retries
       ) do
    case steady_snapshot_plan(
           session,
           remote_agents,
           identity,
           snapshot_started_at,
           agent_now,
           lease_now
         ) do
      {:ok, plan} ->
        :telemetry.execute(
          [:ptc_manager, :herdr, :snapshot, :planned],
          %{agent_count: plan.agent_count, transition_count: length(plan.observations)},
          %{session: session}
        )

        case apply_steady_snapshot_plan(plan) do
          {:error, :stale_snapshot_plan} when retries > 0 ->
            persist_snapshot_attempt(
              session,
              remote_agents,
              identity,
              stale_after_ms,
              reconcile_after_ms,
              snapshot_started_at,
              agent_now,
              lease_now,
              retries - 1
            )

          {:error, :stale_snapshot_plan} ->
            {:error, :concurrent_state_change}

          result ->
            result
        end

      :complex_snapshot ->
        persist_complex_snapshot(
          session,
          remote_agents,
          identity,
          stale_after_ms,
          reconcile_after_ms,
          snapshot_started_at,
          agent_now,
          lease_now
        )
    end
  end

  defp persist_complex_snapshot(
         session,
         remote_agents,
         identity,
         stale_after_ms,
         reconcile_after_ms,
         snapshot_started_at,
         agent_now,
         lease_now
       ) do
    Repo.transaction(
      fn ->
        case DatabaseDiagnostics.with_phase("worker_acceptance", fn ->
               accept_worker_snapshot(session, identity, agent_now, stale_after_ms)
             end) do
          {:ignored, worker, reason} ->
            %{
              worker: worker,
              agent_count: 0,
              lost_count: 0,
              absent_count: 0,
              snapshot_ignored: reason
            }

          {:recovering, worker, reason} ->
            uncertain_count =
              DatabaseDiagnostics.with_phase("run_quarantine", fn ->
                quarantine_active_attempts(worker, agent_now, lease_now, reason)
              end)

            %{
              worker: worker,
              agent_count: 0,
              lost_count: 0,
              absent_count: 0,
              uncertain_count: uncertain_count,
              recovery_pending: true
            }

          {:accepted, worker} ->
            DatabaseDiagnostics.with_phase("snapshot_reconciliation", fn ->
              persist_agents_snapshot(
                worker,
                session,
                remote_agents,
                snapshot_started_at,
                agent_now,
                lease_now,
                reconcile_after_ms
              )
            end)
        end
      end,
      mode: :immediate
    )
  end

  defp steady_snapshot_plan(
         session,
         remote_agents,
         identity,
         snapshot_started_at,
         agent_now,
         lease_now
       )
       when identity != %{} do
    consistent_projection(fn revision ->
      build_steady_snapshot_plan(
        session,
        remote_agents,
        identity,
        snapshot_started_at,
        agent_now,
        lease_now,
        revision
      )
    end)
  end

  defp steady_snapshot_plan(
         _session,
         _remote_agents,
         _identity,
         _snapshot_started_at,
         _agent_now,
         _lease_now
       ),
       do: :complex_snapshot

  defp build_steady_snapshot_plan(
         session,
         remote_agents,
         identity,
         snapshot_started_at,
         agent_now,
         lease_now,
         revision
       ) do
    worker = Repo.get_by(Worker, worker_key: "herdr:#{session}")

    with %Worker{} <- worker,
         true <- settled_worker_snapshot?(worker, identity),
         normalized <- Enum.map(remote_agents, &normalize_agent(&1, session, agent_now)),
         {:ok, observations} <-
           steady_observed_runs(worker, normalized, snapshot_started_at),
         false <-
           live_worker_state?(
             worker,
             Enum.map(observations, & &1.run.id),
             observations |> Enum.map(& &1.run.job_id) |> Enum.reject(&is_nil/1)
           ) do
      {:ok,
       %{
         worker: worker,
         revision: revision,
         identity: identity,
         heartbeat_at: agent_now,
         agent_count: length(normalized),
         lease_now: lease_now,
         observations: observations
       }}
    else
      _other -> :complex_snapshot
    end
  end

  defp consistent_projection(operation, attempts \\ 2)

  defp consistent_projection(_operation, 0), do: :complex_snapshot

  defp consistent_projection(operation, attempts) do
    before_revision = Repo.get!(StateRevision, 1).revision
    result = operation.(before_revision)
    after_revision = Repo.get!(StateRevision, 1).revision

    if before_revision == after_revision do
      result
    else
      consistent_projection(operation, attempts - 1)
    end
  end

  defp settled_worker_snapshot?(worker, identity) do
    worker.status == "online" and worker.healthy_snapshot_count >= 2 and
      worker.worker_incarnation_id == identity.worker_incarnation_id and
      worker.herdr_incarnation_id == identity.herdr_incarnation_id and
      identity.snapshot_sequence > worker.snapshot_sequence
  end

  defp steady_observed_runs(worker, normalized, snapshot_started_at) do
    keys = Enum.map(normalized, & &1.external_key)

    runs =
      AgentRun
      |> where([run], run.worker_id == ^worker.id and run.external_key in ^keys)
      |> order_by([run], desc: run.inserted_at, desc: run.id)
      |> join(:left, [run], job in Job, on: job.id == run.job_id)
      |> select([run, job], {run, job})
      |> Repo.all()
      |> Enum.reduce(%{}, fn {run, job}, acc ->
        Map.put_new(acc, run.external_key, {run, job})
      end)

    observations =
      Enum.map(normalized, fn attrs ->
        classify_steady_observation(
          worker,
          Map.get(runs, attrs.external_key),
          attrs,
          snapshot_started_at
        )
      end)

    if Enum.all?(observations, &is_map/1), do: {:ok, observations}, else: :error
  end

  defp classify_steady_observation(worker, {%AgentRun{} = run, job}, attrs, snapshot_started_at) do
    if snapshot_fresh_for_run?(run, snapshot_started_at) do
      classify_current_observation(worker, run, job, attrs)
    else
      %{
        run: run,
        job: job,
        attrs: Map.put(attrs, :state, run.state),
        transition?: false,
        skip?: true
      }
    end
  end

  defp classify_steady_observation(_worker, _entry, _attrs, _started), do: nil

  defp classify_current_observation(_worker, %AgentRun{state: state} = run, job, attrs)
       when state == attrs.state and state in @terminal_states and
              (is_nil(job) or job.state not in @recoverable_attention_job_states),
       do: %{
         run: run,
         job: job,
         attrs: attrs,
         transition?: false,
         skip?: false,
         settled?: true
       }

  defp classify_current_observation(worker, %AgentRun{state: state} = run, job, attrs)
       when state == attrs.state and state in @terminal_states do
    if active_owned_job?(worker, run, job) do
      %{
        run: run,
        job: job,
        attrs: attrs,
        transition?: false,
        skip?: false,
        reactivated?: false
      }
    end
  end

  defp classify_current_observation(
         _worker,
         %AgentRun{state: "waiting"} = run,
         %Job{state: "pr_open"} = job,
         attrs
       )
       when attrs.state in ["idle", "done"],
       do: %{
         run: run,
         job: job,
         attrs: Map.put(attrs, :state, "waiting"),
         transition?: false,
         skip?: false
       }

  defp classify_current_observation(worker, %AgentRun{state: state} = run, job, attrs)
       when state == attrs.state,
       do: stable_active_observation(worker, run, job, attrs)

  defp classify_current_observation(
         _worker,
         %AgentRun{state: state} = run,
         %Job{state: "pr_open"} = job,
         attrs
       )
       when state in @terminal_states and attrs.state in ["working", "blocked"],
       do: %{
         run: run,
         job: job,
         attrs: Map.put(attrs, :recover_retained, true),
         transition?: state == "lost",
         skip?: false,
         reactivated?: false
       }

  defp classify_current_observation(worker, %AgentRun{state: state} = run, job, attrs)
       when state in @terminal_states and attrs.state in @active_agent_states do
    if active_owned_job?(worker, run, job) do
      %{
        run: run,
        job: job,
        attrs: attrs,
        transition?: false,
        skip?: false,
        reactivated?: true
      }
    end
  end

  defp classify_current_observation(worker, %AgentRun{} = run, job, attrs)
       when run.state not in @terminal_states,
       do: transitioning_active_observation(worker, run, job, attrs)

  defp classify_current_observation(_worker, _run, _job, _attrs), do: nil

  defp stable_active_observation(_worker, %AgentRun{job_id: nil} = run, nil, attrs)
       when run.state not in @terminal_states,
       do: %{run: run, job: nil, attrs: attrs, transition?: false, skip?: false}

  defp stable_active_observation(_worker, _run, nil, _attrs), do: nil

  defp stable_active_observation(worker, run, job, attrs) do
    if run.state not in @terminal_states and job.lease_owner == worker.worker_key and
         job.fencing_token == run.fencing_token and
         job.state in ~w(starting working idle blocked reconciling awaiting_reconciliation) do
      %{run: run, job: job, attrs: attrs, transition?: false, skip?: false}
    end
  end

  defp active_owned_job?(worker, run, job) do
    match?(%Job{}, job) and job.lease_owner == worker.worker_key and
      job.fencing_token == run.fencing_token and
      job.state in ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr)
  end

  defp transitioning_active_observation(_worker, %AgentRun{job_id: nil}, nil, _attrs), do: nil

  defp transitioning_active_observation(worker, run, job, attrs) do
    if job.lease_owner == worker.worker_key and job.fencing_token == run.fencing_token and
         job.state in ~w(starting working idle blocked reconciling awaiting_reconciliation) do
      %{run: run, job: job, attrs: attrs, transition?: true, skip?: false}
    end
  end

  defp live_worker_state?(worker, settled_run_ids, observed_job_ids) do
    active_run? =
      AgentRun
      |> where(
        [run],
        run.worker_id == ^worker.id and run.id not in ^settled_run_ids and
          run.state not in ^@terminal_states
      )
      |> Repo.exists?()

    reconciling_job? =
      Job
      |> where(
        [job],
        job.lease_owner == ^worker.worker_key and job.state == "reconciling" and
          job.id not in ^observed_job_ids
      )
      |> Repo.exists?()

    orphaned_action? = worker |> orphaned_action_runs_query() |> Repo.exists?()

    active_run? or reconciling_job? or orphaned_action?
  end

  defp apply_steady_snapshot_plan(plan) do
    result =
      Repo.transaction(
        fn ->
          worker = plan.worker

          {reserved, _rows} =
            StateRevision
            |> where([revision], revision.id == 1 and revision.revision == ^plan.revision)
            |> Repo.update_all(inc: [revision: 1])

          if reserved != 1, do: Repo.rollback(:stale_snapshot_plan)

          {updated, _rows} =
            Worker
            |> where(
              [candidate],
              candidate.id == ^worker.id and candidate.status == ^worker.status and
                candidate.healthy_snapshot_count == ^worker.healthy_snapshot_count and
                candidate.worker_incarnation_id == ^worker.worker_incarnation_id and
                candidate.herdr_incarnation_id == ^worker.herdr_incarnation_id and
                candidate.snapshot_sequence == ^worker.snapshot_sequence
            )
            |> Repo.update_all(
              set: [
                status: "online",
                capabilities:
                  worker_attrs(worker_session(worker), "online", plan.heartbeat_at, %{}).capabilities,
                last_heartbeat_at: plan.heartbeat_at,
                snapshot_sequence: plan.identity.snapshot_sequence,
                healthy_snapshot_count: max(worker.healthy_snapshot_count, 2),
                coordinator_incarnation_id: RuntimeIncarnation.current(),
                updated_at: plan.heartbeat_at
              ]
            )

          if updated != 1, do: Repo.rollback(:stale_snapshot_plan)

          Enum.each(plan.observations, fn observation ->
            if observation.transition? do
              upsert_agent_run(worker, observation.run, observation.attrs)
            end
          end)

          plan.observations
          |> Enum.reject(
            &(&1.skip? or &1.attrs.state in @terminal_states or
                (&1.run.state in @terminal_states and not &1.transition?))
          )
          |> Enum.group_by(& &1.attrs.state, & &1.run.id)
          |> Enum.each(fn {state, run_ids} ->
            {heartbeat_count, _rows} =
              AgentRun
              |> where(
                [run],
                run.id in ^run_ids and run.worker_id == ^worker.id and run.state == ^state
              )
              |> Repo.update_all(set: [last_heartbeat_at: plan.heartbeat_at])

            if heartbeat_count != length(run_ids), do: Repo.rollback(:stale_snapshot_plan)
          end)

          Enum.each(plan.observations, fn observation ->
            apply_steady_observation(observation, plan.heartbeat_at, plan.lease_now)
          end)

          updated_worker = %{
            worker
            | status: "online",
              capabilities:
                worker_attrs(worker_session(worker), "online", plan.heartbeat_at, %{}).capabilities,
              last_heartbeat_at: plan.heartbeat_at,
              snapshot_sequence: plan.identity.snapshot_sequence,
              healthy_snapshot_count: max(worker.healthy_snapshot_count, 2),
              coordinator_incarnation_id: RuntimeIncarnation.current(),
              updated_at: plan.heartbeat_at
          }

          %{
            worker: updated_worker,
            agent_count: plan.agent_count,
            lost_count: 0,
            absent_count: 0
          }
        end,
        mode: :immediate
      )

    result
  end

  defp apply_steady_observation(%{skip?: true}, _agent_now, _lease_now), do: :ok

  defp apply_steady_observation(%{settled?: true}, _agent_now, _lease_now), do: :ok

  defp apply_steady_observation(observation, agent_now, lease_now) do
    %{run: run, job: job, attrs: attrs} = observation
    reconcile_worktree_identity(run, attrs, agent_now, job)

    cond do
      Map.get(observation, :reactivated?, false) ->
        job
        |> Job.changeset(%{
          state: "reconciling",
          lease_expires_at: nil,
          reconciling_at: lease_now,
          absence_observed_at: nil,
          last_error: "A terminal managed agent identity became active again."
        })
        |> Repo.update!()

      job && job.state in ~w(starting working idle blocked reconciling awaiting_reconciliation) ->
        update_job_from_agent(job, attrs.state, agent_now, lease_now)

      true ->
        :ok
    end

    :ok
  end

  defp persist_agents_snapshot(
         worker,
         session,
         remote_agents,
         snapshot_started_at,
         agent_now,
         lease_now,
         reconcile_after_ms
       ) do
    normalized =
      Enum.map(remote_agents, fn agent ->
        agent
        |> normalize_agent(session, agent_now)
        |> Map.put(:snapshot_started_at, snapshot_started_at)
        |> Map.merge(%{
          worker_incarnation_id: worker.worker_incarnation_id,
          herdr_incarnation_id: worker.herdr_incarnation_id,
          coordinator_incarnation_id: worker.coordinator_incarnation_id
        })
      end)

    {existing_runs, existing_job_states, active_owner_job_ids} =
      DatabaseDiagnostics.with_phase("existing_run_lookup", fn ->
        AgentRun
        |> where([run], run.worker_id == ^worker.id and not is_nil(run.external_key))
        |> order_by([run], desc: run.inserted_at, desc: run.id)
        |> join(:left, [run], job in Job, on: job.id == run.job_id)
        |> select([run, job], {run, job.state})
        |> Repo.all()
        |> Enum.reduce(
          {%{}, %{}, MapSet.new()},
          fn {run, job_state}, {runs, job_states, active_job_ids} ->
            runs = Map.put_new(runs, run.external_key, run)
            job_states = Map.put(job_states, run.id, job_state)

            active_job_ids =
              if job_state in @recoverable_attention_job_states do
                MapSet.put(active_job_ids, run.job_id)
              else
                active_job_ids
              end

            {runs, job_states, active_job_ids}
          end
        )
      end)

    normalized =
      DatabaseDiagnostics.with_phase("snapshot_classification", fn ->
        Enum.map(normalized, fn attrs ->
          case Map.get(existing_runs, attrs.external_key) do
            %AgentRun{} = existing_run ->
              preserve_existing_attachment(attrs, existing_run, existing_job_states)

            nil ->
              attrs
              |> maybe_attach_managed_attempt(worker.worker_key)
              |> maybe_attach_agent_action_attempt(worker)
          end
        end)
      end)

    observed_keys = MapSet.new(normalized, & &1.external_key)

    observed_run_ids =
      DatabaseDiagnostics.with_phase("run_reconciliation", fn ->
        Enum.flat_map(normalized, fn attrs ->
          existing_run = attrs[:managed_run] || Map.get(existing_runs, attrs.external_key)

          cond do
            not snapshot_fresh_for_run?(existing_run, snapshot_started_at) ->
              [existing_run.id]

            settled_terminal_snapshot?(existing_run, attrs, active_owner_job_ids) ->
              [existing_run.id]

            true ->
              run = upsert_agent_run(worker, existing_run, attrs)
              superseded_ids = supersede_duplicate_action_runs(worker, run, attrs, agent_now)
              shared_ids = refresh_shared_pane_runs(worker, run, attrs, agent_now)
              reconcile_worktree_identity(run, attrs, agent_now)
              reconcile_job(run, attrs.state, agent_now, lease_now)
              [run.id | superseded_ids ++ shared_ids]
          end
        end)
        |> MapSet.new()
      end)

    DatabaseDiagnostics.with_phase("heartbeat_refresh", fn ->
      refresh_heartbeats(observed_run_ids, agent_now)
    end)

    lost_count =
      DatabaseDiagnostics.with_phase("missing_run_resolution", fn ->
        mark_missing_runs_lost(
          existing_runs,
          observed_keys,
          observed_run_ids,
          agent_now,
          snapshot_started_at,
          lease_now
        ) + mark_orphaned_action_runs_lost(worker, observed_run_ids, agent_now)
      end)

    absent_count =
      DatabaseDiagnostics.with_phase("absence_resolution", fn ->
        resolve_absent_reconciling_jobs(
          worker,
          normalized,
          lease_now,
          reconcile_after_ms,
          agent_now
        )
      end)

    %{
      worker: worker,
      agent_count: length(normalized),
      lost_count: lost_count,
      absent_count: absent_count
    }
  end

  defp normalize_snapshot(agents) when is_list(agents), do: {:ok, agents, %{}}

  defp normalize_snapshot(snapshot) when is_map(snapshot) do
    agents = value(snapshot, [:agents, "agents"])

    identity = %{
      worker_incarnation_id: value(snapshot, [:worker_incarnation_id, "worker_incarnation_id"]),
      herdr_incarnation_id: value(snapshot, [:herdr_incarnation_id, "herdr_incarnation_id"]),
      snapshot_sequence: value(snapshot, [:snapshot_sequence, "snapshot_sequence"]),
      restart_reason: value(snapshot, [:restart_reason, "restart_reason"])
    }

    present =
      Enum.count(
        [:worker_incarnation_id, :herdr_incarnation_id, :snapshot_sequence],
        &(not is_nil(Map.fetch!(identity, &1)))
      )

    cond do
      not is_list(agents) ->
        {:error, :invalid_herdr_snapshot}

      present == 0 ->
        {:ok, agents, %{}}

      present == 3 and is_binary(identity.worker_incarnation_id) and
        identity.worker_incarnation_id != "" and is_binary(identity.herdr_incarnation_id) and
        identity.herdr_incarnation_id != "" and is_integer(identity.snapshot_sequence) and
          identity.snapshot_sequence > 0 ->
        {:ok, agents, identity}

      true ->
        {:error, :invalid_herdr_snapshot_identity}
    end
  end

  defp normalize_snapshot(_snapshot), do: {:error, :invalid_herdr_snapshot}

  defp accept_worker_snapshot(session, identity, heartbeat_at, _stale_after_ms)
       when identity == %{} do
    key = "herdr:#{session}"

    case Repo.get_by(Worker, worker_key: key) do
      %Worker{worker_incarnation_id: incarnation} = worker when not is_nil(incarnation) ->
        updated =
          update_worker(worker, "degraded", nil, %{
            healthy_snapshot_count: 0,
            restart_reason: "Authoritative snapshot identity was missing.",
            coordinator_incarnation_id: nil
          })

        {:recovering, updated,
         "Authoritative snapshot identity was missing; retained work must be reconciled."}

      _legacy_worker ->
        worker =
          upsert_worker(session, "online", heartbeat_at, %{
            coordinator_incarnation_id: RuntimeIncarnation.current()
          })

        {:accepted, worker}
    end
  end

  defp accept_worker_snapshot(session, identity, heartbeat_at, stale_after_ms) do
    key = "herdr:#{session}"

    case Repo.get_by(Worker, worker_key: key) do
      nil ->
        worker =
          insert_worker(session, "online", heartbeat_at, %{
            worker_incarnation_id: identity.worker_incarnation_id,
            herdr_incarnation_id: identity.herdr_incarnation_id,
            snapshot_sequence: identity.snapshot_sequence,
            healthy_snapshot_count: 2,
            restart_reason: identity.restart_reason,
            coordinator_incarnation_id: RuntimeIncarnation.current()
          })

        {:accepted, worker}

      %Worker{worker_incarnation_id: nil, herdr_incarnation_id: nil} = worker ->
        worker =
          update_worker(worker, "online", heartbeat_at, %{
            worker_incarnation_id: identity.worker_incarnation_id,
            herdr_incarnation_id: identity.herdr_incarnation_id,
            snapshot_sequence: identity.snapshot_sequence,
            healthy_snapshot_count: 2,
            restart_reason: identity.restart_reason,
            coordinator_incarnation_id: RuntimeIncarnation.current()
          })

        {:accepted, worker}

      %Worker{} = worker ->
        classify_worker_snapshot(worker, identity, heartbeat_at, stale_after_ms)
    end
  end

  defp classify_worker_snapshot(worker, identity, heartbeat_at, stale_after_ms) do
    current_identity = {worker.worker_incarnation_id, worker.herdr_incarnation_id}
    observed_identity = {identity.worker_incarnation_id, identity.herdr_incarnation_id}

    previous_identity =
      {worker.previous_worker_incarnation_id, worker.previous_herdr_incarnation_id}

    cond do
      observed_identity == current_identity and
          identity.snapshot_sequence <= worker.snapshot_sequence ->
        classify_stale_snapshot(
          worker,
          heartbeat_at,
          stale_after_ms,
          :stale_sequence,
          "Authoritative snapshot sequence stopped advancing."
        )

      observed_identity == previous_identity ->
        classify_stale_snapshot(
          worker,
          heartbeat_at,
          stale_after_ms,
          :stale_incarnation,
          "Only a previous worker incarnation is reporting."
        )

      observed_identity != current_identity ->
        changed_at = heartbeat_at

        updated =
          update_worker(worker, "degraded", heartbeat_at, %{
            previous_worker_incarnation_id: worker.worker_incarnation_id,
            previous_herdr_incarnation_id: worker.herdr_incarnation_id,
            worker_incarnation_id: identity.worker_incarnation_id,
            herdr_incarnation_id: identity.herdr_incarnation_id,
            snapshot_sequence: identity.snapshot_sequence,
            healthy_snapshot_count: 1,
            restart_reason: identity.restart_reason,
            incarnation_changed_at: changed_at,
            coordinator_incarnation_id: nil
          })

        record_incarnation_change(worker, updated, identity)

        {:recovering, updated,
         "Worker or Herdr incarnation changed; retained work must be reconciled."}

      worker.status == "degraded" and worker.healthy_snapshot_count < 2 ->
        healthy_count = worker.healthy_snapshot_count + 1
        status = if healthy_count >= 2, do: "online", else: "degraded"

        updated =
          update_worker(worker, status, heartbeat_at, %{
            snapshot_sequence: identity.snapshot_sequence,
            healthy_snapshot_count: healthy_count,
            coordinator_incarnation_id:
              if(status == "online", do: RuntimeIncarnation.current(), else: nil)
          })

        if status == "online" do
          {:accepted, updated}
        else
          {:recovering, updated, "Waiting for consecutive healthy worker snapshots."}
        end

      true ->
        updated =
          update_worker(worker, "online", heartbeat_at, %{
            snapshot_sequence: identity.snapshot_sequence,
            healthy_snapshot_count: max(worker.healthy_snapshot_count, 2),
            coordinator_incarnation_id: RuntimeIncarnation.current()
          })

        {:accepted, updated}
    end
  end

  defp snapshot_expired?(%Worker{last_heartbeat_at: nil}, _heartbeat_at, _stale_after_ms),
    do: true

  defp snapshot_expired?(worker, heartbeat_at, stale_after_ms),
    do: DateTime.diff(heartbeat_at, worker.last_heartbeat_at, :millisecond) >= stale_after_ms

  defp classify_stale_snapshot(
         worker,
         heartbeat_at,
         stale_after_ms,
         ignored_reason,
         degraded_reason
       ) do
    if snapshot_expired?(worker, heartbeat_at, stale_after_ms) do
      updated =
        update_worker(worker, "degraded", nil, %{
          healthy_snapshot_count: 0,
          restart_reason: degraded_reason,
          coordinator_incarnation_id: nil
        })

      {:recovering, updated, "#{degraded_reason} Retained work must be reconciled."}
    else
      {:ignored, worker, ignored_reason}
    end
  end

  defp quarantine_active_attempts(worker, agent_now, lease_now, reason) do
    jobs =
      Job
      |> where(
        [job],
        job.lease_owner == ^worker.worker_key and
          job.state in ["starting", "working", "idle", "blocked", "reconciling"]
      )
      |> Repo.all()

    Enum.each(jobs, &mark_job_recovery_pending(&1, agent_now, lease_now, reason))

    runs =
      AgentRun
      |> where(
        [run],
        run.worker_id == ^worker.id and
          run.state in ["starting", "working", "idle", "blocked", "unknown"]
      )
      |> Repo.all()

    Enum.each(runs, fn run ->
      mark_managed_run_uncertain(run, agent_now, lease_now, reason)
    end)

    max(length(jobs), length(runs))
  end

  defp mark_job_recovery_pending(job, agent_now, lease_now, reason) do
    job
    |> Job.changeset(%{
      state: "reconciling",
      lease_expires_at: nil,
      reconciling_at: job.reconciling_at || lease_now,
      absence_observed_at: nil,
      last_error: reason
    })
    |> Repo.update!()

    mark_worktree_attention(job.id, reason, agent_now)
  end

  defp record_incarnation_change(previous, current, identity) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: "worker:#{current.worker_key}",
      action: "worker.incarnation_changed",
      target_type: "worker",
      target_id: current.id,
      details: %{
        "previous_worker_incarnation_id" => previous.worker_incarnation_id,
        "worker_incarnation_id" => current.worker_incarnation_id,
        "previous_herdr_incarnation_id" => previous.herdr_incarnation_id,
        "herdr_incarnation_id" => current.herdr_incarnation_id,
        "snapshot_sequence" => identity.snapshot_sequence,
        "restart_reason" => identity.restart_reason
      }
    })
    |> Repo.insert!()
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
      agent_name: value(agent, ["display_agent", "name", "agent_name", "agent"])
    }
  end

  defp upsert_agent_run(worker, nil, attrs) do
    insert_agent_run(worker, attrs)
  end

  defp upsert_agent_run(
         _worker,
         %AgentRun{agent_action_id: action_id, state: "starting"} = run,
         attrs
       )
       when is_integer(action_id) do
    attrs =
      attrs
      |> Map.put(:state, "starting")
      |> Map.put(:started_at, run.started_at)
      |> Map.put(:ended_at, nil)
      |> Map.put(:status_text, run.status_text)
      |> preserve_identity(run)

    update_run!(run, attrs)
  end

  defp upsert_agent_run(
         _worker,
         %AgentRun{job_id: job_id, state: previous_state} = run,
         %{state: "waiting"} = attrs
       )
       when not is_nil(job_id) and previous_state in @terminal_states do
    attrs =
      attrs
      |> Map.put(:started_at, run.started_at)
      |> Map.put(:ended_at, nil)
      |> preserve_identity(run)

    update_run!(run, attrs)
  end

  defp upsert_agent_run(
         _worker,
         %AgentRun{agent_action_id: action_id, state: "waiting"} = run,
         %{state: observed_state} = attrs
       )
       when is_integer(action_id) and observed_state in ["idle", "done", "waiting"] do
    attrs =
      attrs
      |> Map.put(:state, "waiting")
      |> Map.put(:started_at, run.started_at)
      |> Map.put(:ended_at, nil)
      |> Map.put(:status_text, "Retained with its pull request; waiting for merge or closure.")
      |> preserve_identity(run)

    update_run!(run, attrs)
  end

  defp upsert_agent_run(
         _worker,
         %AgentRun{state: "lost"} = run,
         %{recover_retained: true, state: state} = attrs
       )
       when state in ["working", "blocked"] do
    attrs =
      attrs
      |> Map.put(:started_at, run.started_at)
      |> Map.put(:ended_at, nil)
      |> preserve_identity(run)

    update_run!(run, attrs)
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

    update_run!(run, attrs)
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
    attrs = attrs |> Map.put(:started_at, run.started_at) |> preserve_identity(run)
    update_run!(run, attrs)
  end

  defp preserve_identity(attrs, run) do
    Enum.reduce([:agent_name, :herdr_workspace, :herdr_pane, :herdr_session], attrs, fn key,
                                                                                        acc ->
      if Map.get(acc, key) in [nil, ""], do: Map.put(acc, key, Map.get(run, key)), else: acc
    end)
  end

  # Most ticks observe the same agents in the same state. Writing the heartbeat
  # through the changeset rewrote every run and its `updated_at` inside the
  # write transaction on every tick; an unchanged run now produces an empty
  # changeset, and one statement refreshes every observed heartbeat.
  defp update_run!(run, attrs) do
    run |> AgentRun.changeset(Map.delete(attrs, :last_heartbeat_at)) |> Repo.update!()
  end

  defp refresh_heartbeats(run_ids, now) do
    ids = MapSet.to_list(run_ids)

    AgentRun
    |> where([run], run.id in ^ids and run.state not in ^@terminal_states)
    |> Repo.update_all(set: [last_heartbeat_at: now])
  end

  # Allocation timestamps order least-recently-used cleanup; a live worktree
  # is touched once a minute instead of on every tick.
  defp touch_cutoff(now), do: DateTime.add(now, -@touch_interval_ms, :millisecond)

  defp insert_agent_run(worker, attrs) do
    %AgentRun{}
    |> AgentRun.changeset(Map.put(attrs, :worker_id, worker.id))
    |> Repo.insert!()
  end

  defp snapshot_fresh_for_run?(nil, _snapshot_started_at), do: true

  defp snapshot_fresh_for_run?(%AgentRun{updated_at: updated_at}, snapshot_started_at),
    do: DateTime.compare(updated_at, snapshot_started_at) != :gt

  # Herdr retains completed panes in every snapshot. Once the owning job has
  # left the agent-driven states, replaying the same terminal observation cannot
  # add information. Skipping it avoids two no-op worktree UPDATE statements per
  # retained pane while SQLite's only writer lock is held. An active owner must
  # still reconcile: a terminal pane can report working and then terminal again.
  defp settled_terminal_snapshot?(
         %AgentRun{state: state, job_id: job_id},
         %{state: state},
         active_owner_job_ids
       )
       when state in @terminal_states,
       do: not MapSet.member?(active_owner_job_ids, job_id)

  defp settled_terminal_snapshot?(_run, _attrs, _active_owner_job_ids), do: false

  defp mark_missing_runs_lost(
         existing_runs,
         observed_keys,
         observed_run_ids,
         now,
         snapshot_started_at,
         lease_now
       ) do
    missing_runs =
      existing_runs
      |> Map.values()
      |> Enum.reject(
        &(&1.state in @terminal_states or MapSet.member?(observed_keys, &1.external_key) or
            MapSet.member?(observed_run_ids, &1.id) or
            not snapshot_fresh_for_run?(&1, snapshot_started_at))
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

      if lost.job_id do
        mark_worktree_attention(
          lost.job_id,
          @missing_retained_error,
          now
        )
      end

      reconcile_job(lost, "lost", now, lease_now)
    end)

    length(missing_runs)
  end

  # An action run that lost its Herdr identity during an outage after its
  # action already finished is observed by nothing: no live agent maps back to
  # it, and the missing-run check only knows runs with an external key. Left
  # as "unknown" it would hold deployments forever.
  defp mark_orphaned_action_runs_lost(worker, observed_run_ids, now) do
    worker
    |> orphaned_action_runs_query()
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(observed_run_ids, &1.id))
    |> Enum.map(fn run ->
      run
      |> AgentRun.changeset(%{
        state: "lost",
        status_text: "The action finished; no Herdr agent remains for this record.",
        last_heartbeat_at: now,
        ended_at: now
      })
      |> Repo.update!()
    end)
    |> length()
  end

  defp orphaned_action_runs_query(worker) do
    AgentRun
    |> join(:inner, [run], action in assoc(run, :agent_action))
    |> where(
      [run, action],
      run.worker_id == ^worker.id and run.state == "unknown" and is_nil(run.job_id) and
        action.state in ^@terminal_action_states
    )
  end

  defp upsert_worker(session, status, heartbeat_at, extra_attrs) do
    key = "herdr:#{session}"

    case Repo.get_by(Worker, worker_key: key) do
      nil -> insert_worker(session, status, heartbeat_at, extra_attrs)
      worker -> update_worker(worker, status, heartbeat_at, extra_attrs)
    end
  end

  defp insert_worker(session, status, heartbeat_at, extra_attrs) do
    attrs = worker_attrs(session, status, heartbeat_at, extra_attrs)
    %Worker{} |> Worker.changeset(attrs) |> Repo.insert!()
  end

  defp update_worker(worker, status, heartbeat_at, extra_attrs) do
    attrs = worker_attrs(worker_session(worker), status, heartbeat_at, extra_attrs)
    worker |> Worker.changeset(attrs) |> Repo.update!()
  end

  defp worker_attrs(session, status, heartbeat_at, extra_attrs) do
    attrs =
      %{
        worker_key: "herdr:#{session}",
        name: "Herdr #{session}",
        status: status,
        capabilities: %{
          "herdr" => true,
          "agent_kinds" =>
            Application.get_env(:ptc_manager, :agent_profiles, %{})
            |> Enum.filter(fn {_kind, profile} -> profile["enabled"] == true end)
            |> Enum.map(&elem(&1, 0))
            |> Enum.sort(),
          "implementation_slots" => Application.get_env(:ptc_manager, :heavy_agent_capacity, 1)
        }
      }
      |> Map.merge(extra_attrs)

    if heartbeat_at, do: Map.put(attrs, :last_heartbeat_at, heartbeat_at), else: attrs
  end

  defp worker_session(%Worker{worker_key: "herdr:" <> session}), do: session

  defp mark_degraded(session, reason, stale_after_ms, agent_now, lease_now) do
    result =
      Repo.transaction(
        fn ->
          worker =
            upsert_worker(session, "degraded", nil, %{
              healthy_snapshot_count: 0,
              coordinator_incarnation_id: nil
            })

          {lost_count, uncertain_count} =
            mark_stale_runs_lost(worker, agent_now, stale_after_ms, lease_now)

          %{worker: worker, lost_count: lost_count, uncertain_count: uncertain_count}
        end,
        mode: :immediate
      )

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

  defp mark_stale_runs_lost(worker, agent_now, stale_after_ms, lease_now) do
    active_runs =
      AgentRun
      |> where([run], run.worker_id == ^worker.id and run.state not in ^@terminal_states)
      |> Repo.all()

    stale_runs =
      Enum.filter(active_runs, fn run ->
        DateTime.diff(agent_now, run.last_heartbeat_at, :millisecond) >= stale_after_ms
      end)

    Enum.reduce(stale_runs, {0, 0}, fn run, {lost_count, uncertain_count} ->
      if run.job_id || run.agent_action_id do
        mark_managed_run_uncertain(run, agent_now, lease_now)
        {lost_count, uncertain_count + 1}
      else
        lost =
          run
          |> AgentRun.changeset(%{
            state: "lost",
            status_text: "Herdr could not confirm this agent after the heartbeat deadline.",
            ended_at: agent_now
          })
          |> Repo.update!()

        reconcile_job(lost, "lost", agent_now, lease_now)
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

  defp reconcile_job(%AgentRun{job_id: nil}, _agent_state, _agent_now, _lease_now), do: :ok

  defp reconcile_job(
         %AgentRun{state: run_state} = run,
         agent_state,
         _agent_now,
         lease_now
       )
       when run_state in @terminal_states and agent_state in @active_agent_states do
    case owned_job(run) do
      %Job{fencing_token: token, state: state} = job
      when token == run.fencing_token and
             state in ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr) ->
        job
        |> Job.changeset(%{
          state: "reconciling",
          lease_expires_at: nil,
          reconciling_at: lease_now,
          absence_observed_at: nil,
          last_error: "A terminal managed agent identity became active again."
        })
        |> Repo.update!()

      _job ->
        :ok
    end
  end

  # Herdr restores every pane as `idle` after a restart, and a finished agent
  # keeps its pane until the retained worktree is removed. Neither is a writer,
  # so only an active status may re-park a job whose run already ended.
  defp reconcile_job(%AgentRun{state: run_state}, agent_state, _agent_now, _lease_now)
       when run_state in @terminal_states and agent_state not in @terminal_states,
       do: :ok

  defp reconcile_job(%AgentRun{} = run, agent_state, agent_now, lease_now) do
    case owned_job(run) do
      %Job{fencing_token: token, state: state} = job
      when token == run.fencing_token and
             state in ~w(starting working idle blocked reconciling awaiting_reconciliation) ->
        update_job_from_agent(job, agent_state, agent_now, lease_now)

      _job ->
        :ok
    end
  end

  defp update_job_from_agent(job, agent_state, agent_now, lease_now) do
    state =
      if PtcManager.Reviews.held?(job), do: "blocked", else: job_state(agent_state, job.state)

    attrs =
      cond do
        PtcManager.Reviews.held?(job) ->
          %{
            state: "blocked",
            lease_expires_at: nil,
            reconciling_at: nil,
            absence_observed_at: nil
          }

        state in ~w(failed lost) ->
          %{
            state: state,
            ended_at: agent_now,
            lease_expires_at: nil,
            reconciling_at: nil,
            absence_observed_at: nil
          }

        state == "awaiting_reconciliation" ->
          %{
            state: state,
            lease_expires_at: nil,
            reconciling_at: lease_now,
            absence_observed_at: nil
          }

        state == "idle" ->
          idle_timeout_ms =
            Application.get_env(:ptc_manager, :implementation_idle_timeout_ms, 300_000)

          idle_deadline =
            if job.state == "idle" && job.lease_expires_at,
              do: job.lease_expires_at,
              else: DateTime.add(lease_now, idle_timeout_ms, :millisecond)

          %{
            state: state,
            lease_expires_at: idle_deadline,
            reconciling_at: nil,
            absence_observed_at: nil
          }

        true ->
          lease_ms = Application.get_env(:ptc_manager, :dispatch_lease_ms, 1_800_000)

          %{
            state: state,
            lease_expires_at: DateTime.add(lease_now, lease_ms, :millisecond),
            reconciling_at: nil,
            absence_observed_at: nil
          }
      end

    job |> Job.changeset(attrs) |> Repo.update!()

    if state in ~w(failed lost) do
      mark_worktree_attention(
        job.id,
        "The implementation agent ended in state #{state}.",
        agent_now
      )
    end

    :ok
  end

  defp job_state("working", _current), do: "working"
  defp job_state("blocked", _current), do: "blocked"
  defp job_state("idle", _current), do: "idle"
  defp job_state("done", _current), do: "awaiting_reconciliation"
  defp job_state("failed", _current), do: "failed"
  defp job_state("lost", _current), do: "lost"
  defp job_state(_state, current), do: current

  defp preserve_existing_attachment(attrs, existing_run, existing_job_states) do
    if Map.get(existing_job_states, existing_run.id) == "pr_open" do
      attrs = Map.put(attrs, :recover_retained, existing_run.state == "lost")

      if attrs.state in ["done", "idle"] do
        attrs
        |> Map.put(:state, "waiting")
        |> Map.put(:ended_at, nil)
        |> Map.put(
          :status_text,
          "Retained with its PR context; waiting for CI or maintainer action."
        )
      else
        attrs
      end
    else
      attrs
    end
  end

  defp maybe_attach_managed_attempt(%{agent_name: name} = attrs, worker_key)
       when is_binary(name) do
    with [job_id, fencing_token] <-
           Regex.run(~r/^impl_j(\d+)_f(\d+)(?:_r\d+)?$/, name, capture: :all_but_first),
         {job_id, ""} <- Integer.parse(job_id),
         {fencing_token, ""} <- Integer.parse(fencing_token),
         %Job{fencing_token: ^fencing_token, state: state, lease_owner: ^worker_key} = job <-
           Repo.get(Job, job_id),
         true <-
           state in ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr pr_open) do
      managed_run = Repo.get_by(AgentRun, job_id: job.id, fencing_token: fencing_token)

      if managed_run && managed_run.agent_name not in [nil, name] do
        attrs
      else
        attrs =
          attrs
          |> Map.put(:job_id, job.id)
          |> Map.put(:fencing_token, fencing_token)
          |> Map.put(:managed_run, managed_run)
          |> Map.put(
            :recover_retained,
            state == "pr_open" and match?(%AgentRun{state: "lost"}, managed_run)
          )

        if state == "pr_open" and attrs.state in ["done", "idle"] do
          attrs
          |> Map.put(:state, "waiting")
          |> Map.put(:ended_at, nil)
          |> Map.put(
            :status_text,
            "Retained with its PR context; waiting for CI or maintainer action."
          )
        else
          attrs
        end
      end
    else
      _ -> attrs
    end
  end

  defp maybe_attach_managed_attempt(attrs, _worker_key), do: attrs

  defp maybe_attach_agent_action_attempt(%{agent_name: name} = attrs, worker)
       when is_binary(name) do
    with [action_id, fencing_token] <-
           Regex.run(
             ~r/^(?:(?:merge|repair)_pr\d+|automation)_a(\d+)_f(\d+)$/,
             name,
             capture: :all_but_first
           ),
         {action_id, ""} <- Integer.parse(action_id),
         {fencing_token, ""} <- Integer.parse(fencing_token),
         %AgentRun{} = action_run <-
           AgentRun
           |> where(
             [run],
             run.agent_action_id == ^action_id and run.fencing_token == ^fencing_token and
               run.worker_id == ^worker.id and
               run.state in ["starting", "working", "idle", "blocked", "waiting", "unknown"]
           )
           |> order_by([run], desc: run.id)
           |> limit(1)
           |> Repo.one() do
      attrs
      |> Map.put(:agent_action_id, action_id)
      |> Map.put(:fencing_token, fencing_token)
      |> Map.put(:managed_run, action_run)
    else
      _failure -> attrs
    end
  end

  defp maybe_attach_agent_action_attempt(attrs, _worker), do: attrs

  defp supersede_duplicate_action_runs(
         worker,
         %AgentRun{agent_action_id: action_id} = retained,
         attrs,
         now
       )
       when is_integer(action_id) do
    workspace = attrs.herdr_workspace || retained.herdr_workspace
    pane = attrs.herdr_pane || retained.herdr_pane
    name = attrs.agent_name || retained.agent_name

    duplicates =
      AgentRun
      |> where(
        [run],
        run.worker_id == ^worker.id and run.id != ^retained.id and is_nil(run.job_id) and
          is_nil(run.agent_action_id) and run.agent_name == ^name and
          ((not is_nil(^workspace) and run.herdr_workspace == ^workspace) or
             (not is_nil(^pane) and run.herdr_pane == ^pane))
      )
      |> Repo.all()

    Enum.each(duplicates, fn duplicate ->
      attrs =
        if duplicate.state in @terminal_states do
          %{status_text: @superseded_status}
        else
          %{
            state: "lost",
            status_text: @superseded_status,
            last_heartbeat_at: now,
            ended_at: now
          }
        end

      duplicate |> AgentRun.changeset(attrs) |> Repo.update!()
    end)

    Enum.map(duplicates, & &1.id)
  end

  defp supersede_duplicate_action_runs(_worker, _run, _attrs, _now), do: []

  # A retained repair resumes the job's implementation session, so its action
  # run carries the same agent name as the job's run while Herdr reports the
  # pane once, under the job's name. Every live action run bound to that pane
  # follows the observation on every tick: while the pane executes, the run
  # takes that state, which also recovers a run an outage marked unknown; a
  # pane that is idle or parked leaves the run alone, because the action's
  # adapter is what finishes it. The ids join the observed set, so the shared
  # heartbeat statement keeps them fresh without a write of their own. Without
  # this the action run froze in `starting` and read as out of contact while
  # its agent was working.
  defp refresh_shared_pane_runs(
         worker,
         %AgentRun{agent_name: name, job_id: job_id} = run,
         attrs,
         _now
       )
       when is_binary(name) and is_integer(job_id) do
    AgentRun
    |> where(
      [other],
      other.worker_id == ^worker.id and other.id != ^run.id and other.agent_name == ^name and
        not is_nil(other.agent_action_id) and other.state in ^@shared_pane_states
    )
    |> Repo.all()
    |> Enum.map(fn other ->
      if other.state != attrs.state and attrs.state in @executing_pane_states do
        other |> AgentRun.changeset(%{state: attrs.state}) |> Repo.update!()
      end

      other.id
    end)
  end

  defp refresh_shared_pane_runs(_worker, _run, _attrs, _now), do: []

  defp mark_managed_run_uncertain(
         run,
         agent_now,
         lease_now,
         message \\ "Herdr transport is unavailable; remote activity must be reconciled."
       ) do
    run
    |> AgentRun.changeset(%{
      state: "unknown",
      status_text: message
    })
    |> Repo.update!()

    case owned_job(run) do
      %Job{fencing_token: token, state: state} = job
      when token == run.fencing_token and state in ~w(starting working idle blocked reconciling) ->
        job
        |> Job.changeset(%{
          state: "reconciling",
          lease_expires_at: nil,
          reconciling_at: job.reconciling_at || lease_now,
          absence_observed_at: nil,
          last_error: message
        })
        |> Repo.update!()

        mark_worktree_attention(
          job.id,
          message,
          agent_now
        )

      _job ->
        :ok
    end
  end

  defp resolve_absent_reconciling_jobs(
         worker,
         normalized,
         lease_now,
         reconcile_after_ms,
         lifecycle_now
       ) do
    observed_states = Map.new(normalized, &{&1.agent_name, &1.state})

    Job
    |> where(
      [job],
      job.state == "reconciling" and job.lease_owner == ^worker.worker_key
    )
    |> Repo.all()
    |> Enum.count(fn job ->
      run = Repo.get_by(AgentRun, job_id: job.id, fencing_token: job.fencing_token)
      attempt_name = (run && run.agent_name) || "impl_j#{job.id}_f#{job.fencing_token}"

      old_enough =
        job.reconciling_at &&
          DateTime.diff(lease_now, job.reconciling_at, :millisecond) >= reconcile_after_ms

      cond do
        PtcManager.Reviews.held?(job) ->
          settle_held_reconciling_job(
            job,
            run,
            Map.get(observed_states, attempt_name),
            old_enough == true,
            lifecycle_now
          )

          false

        !old_enough || Map.has_key?(observed_states, attempt_name) ->
          false

        job.absence_observed_at ->
          fail_absent_attempt(job, lifecycle_now)

        true ->
          record_absence_observation(job, lease_now, lifecycle_now)
          false
      end
    end)
  end

  # A paused or manual review parked in `reconciling` keeps its slot only while
  # its agent may still be writing. Once the implementer run is terminal and the
  # snapshot shows the attempt absent or not active, the job returns to
  # `blocked`, where a finished implementer releases capacity and the retained
  # work waits for the maintainer's decision. A `reconciling` stamp without a
  # timestamp came from a recovery that already confirmed the stop.
  defp settle_held_reconciling_job(job, run, observed_state, old_enough, lifecycle_now) do
    settled? =
      match?(%AgentRun{state: state} when state in @terminal_states, run) and
        (is_nil(job.reconciling_at) or old_enough) and
        observed_state not in @active_agent_states

    if settled? do
      {updated, _rows} =
        Job
        |> where(
          [candidate],
          candidate.id == ^job.id and candidate.state == "reconciling" and
            candidate.fencing_token == ^job.fencing_token
        )
        |> Repo.update_all(
          set: [
            state: "blocked",
            lease_expires_at: nil,
            reconciling_at: nil,
            absence_observed_at: nil,
            updated_at: lifecycle_now
          ]
        )

      if updated == 1, do: insert_reconciliation_audit!(job, "job.retained_agent_settled")
    end

    :ok
  end

  defp record_absence_observation(job, lease_now, lifecycle_now) do
    {updated, _rows} =
      Job
      |> where(
        [candidate],
        candidate.id == ^job.id and candidate.state == "reconciling" and
          candidate.fencing_token == ^job.fencing_token and
          is_nil(candidate.absence_observed_at)
      )
      |> Repo.update_all(set: [absence_observed_at: lease_now, updated_at: lifecycle_now])

    if updated == 1 do
      insert_reconciliation_audit!(job, "job.agent_absence_observed")
    end
  end

  defp fail_absent_attempt(job, lifecycle_now) do
    message = absent_agent_error(job.last_error)

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
          ended_at: lifecycle_now,
          last_error: message,
          updated_at: lifecycle_now
        ]
      )

    if updated == 1 do
      mark_worktree_attention(job.id, message, lifecycle_now)
      insert_reconciliation_audit!(job, "job.absent_agent_confirmed")

      true
    else
      false
    end
  end

  # The uncertain launch already recorded why dispatch stopped; keep that cause
  # next to the absence confirmation instead of replacing it.
  defp absent_agent_error(previous)
       when is_binary(previous) and previous != "" and previous != @absent_agent_error,
       do: String.slice("#{@absent_agent_error} Earlier error: #{previous}", 0, 500)

  defp absent_agent_error(_previous), do: @absent_agent_error

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

  defp mark_worktree_attention(job_id, message, now) do
    WorktreeAllocation
    |> where(
      [allocation],
      allocation.job_id == ^job_id and
        allocation.state not in ["attention", "terminal", "cleaning", "removed"]
    )
    |> Repo.update_all(
      set: [state: "attention", last_used_at: now, last_error: message, updated_at: now]
    )
  end

  defp reconcile_worktree_identity(run, attrs, now),
    do: reconcile_worktree_identity(run, attrs, now, nil)

  defp reconcile_worktree_identity(
         %AgentRun{job_id: job_id, herdr_workspace: retained_workspace},
         %{herdr_workspace: observed_workspace, state: state} = attrs,
         now,
         job
       )
       when is_integer(job_id) do
    workspace =
      if is_binary(observed_workspace) and observed_workspace != "",
        do: observed_workspace,
        else: retained_workspace

    if is_binary(workspace) and workspace != "" do
      cutoff = touch_cutoff(now)

      WorktreeAllocation
      |> where(
        [allocation],
        allocation.job_id == ^job_id and
          allocation.state not in ["terminal", "cleaning", "removed"] and
          (allocation.herdr_workspace != ^workspace or is_nil(allocation.herdr_workspace) or
             is_nil(allocation.last_used_at) or allocation.last_used_at < ^cutoff)
      )
      |> Repo.update_all(set: [herdr_workspace: workspace, last_used_at: now, updated_at: now])

      reconcile_worktree_state(
        job_id,
        state,
        now,
        Map.get(attrs, :recover_retained, false),
        job
      )
    end

    :ok
  end

  defp reconcile_worktree_identity(_run, _attrs, _now, _job), do: :ok

  defp reconcile_worktree_state(job_id, state, now, recovered_retained?, _job)
       when state in ["working", "idle"] do
    mark_worktree_active(job_id, now, recovered_retained?)
  end

  defp reconcile_worktree_state(job_id, "blocked", now, recovered_retained?, projected_job) do
    case projected_job || Repo.get(Job, job_id) do
      %Job{state: "pr_open"} ->
        transition_observed_worktree(
          job_id,
          ~w(reserved active awaiting_pr warm waiting reclaimable attention),
          "waiting",
          now,
          recovered_retained?
        )

      _job ->
        mark_worktree_active(job_id, now, recovered_retained?)
    end
  end

  defp reconcile_worktree_state(job_id, "waiting", now, recovered_retained?, _job) do
    transition_observed_worktree(
      job_id,
      ~w(reserved active awaiting_pr warm waiting reclaimable attention),
      "waiting",
      now,
      recovered_retained?
    )
  end

  defp reconcile_worktree_state(job_id, "done", now, _recovered_retained?, _job) do
    transition_observed_worktree(
      job_id,
      ~w(reserved active awaiting_pr warm waiting reclaimable),
      "awaiting_pr",
      now,
      false
    )
  end

  defp reconcile_worktree_state(job_id, state, now, _recovered_retained?, _job)
       when state in ["failed", "lost"] do
    mark_worktree_attention(job_id, "The retained Herdr agent ended in state #{state}.", now)
  end

  defp reconcile_worktree_state(_job_id, _state, _now, _recovered_retained?, _job), do: :ok

  defp mark_worktree_active(job_id, now, recovered_retained?) do
    cutoff = touch_cutoff(now)

    WorktreeAllocation
    |> join(:inner, [allocation], job in Job, on: job.id == allocation.job_id)
    |> where(
      [allocation, job],
      allocation.job_id == ^job_id and
        allocation.state not in ["terminal", "cleaning", "removed"] and
        (allocation.state != "attention" or
           job.state in ^@recoverable_attention_job_states or
           (^recovered_retained? and allocation.last_error == ^@missing_retained_error)) and
        (allocation.state != "active" or not is_nil(allocation.last_error) or
           is_nil(allocation.last_used_at) or allocation.last_used_at < ^cutoff)
    )
    |> Repo.update_all(
      set: [state: "active", last_error: nil, last_used_at: now, updated_at: now]
    )
  end

  defp transition_observed_worktree(
         job_id,
         from_states,
         state,
         now,
         recover_missing_attention?
       ) do
    WorktreeAllocation
    |> where(
      [allocation],
      allocation.job_id == ^job_id and allocation.state in ^from_states and
        (allocation.state != "attention" or
           (^recover_missing_attention? and
              allocation.last_error == ^@missing_retained_error))
    )
    |> Repo.update_all(set: [state: state, last_error: nil, last_used_at: now, updated_at: now])
  end

  defp owned_job(%AgentRun{job_id: nil}), do: nil

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
