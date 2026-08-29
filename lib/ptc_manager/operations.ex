defmodule PtcManager.Operations do
  @moduledoc """
  Owns PtcManager's durable issue approvals, jobs, workers, and agent activity.

  GitHub reconciliation and execution adapters will enter through this boundary
  in later slices. Model output is stored as an immutable proposal and never
  performs an external effect directly.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias PtcManager.Repo

  alias PtcManager.Operations.{
    AgentAction,
    AgentRun,
    Approval,
    AuditEvent,
    Issue,
    IssueDependency,
    Job,
    MergeApproval,
    PrAnalysis,
    PrPublication,
    Proposal,
    Repository,
    Worker,
    WorktreeAllocation
  }

  @active_job_states ~w(queued starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open publish_blocked)
  @capacity_job_states ~w(starting working idle blocked reconciling)
  @topic "operations"

  def subscribe, do: Phoenix.PubSub.subscribe(PtcManager.PubSub, @topic)

  def notify_changed(source) do
    Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:operations_changed, source})
  end

  def list_repositories,
    do: Repository |> order_by([repository], asc: repository.id) |> Repo.all()

  def get_repository!(id), do: Repo.get!(Repository, id)

  def get_issue!(id), do: Issue |> preload(:repository) |> Repo.get!(id)

  def create_repository(attrs),
    do: %Repository{} |> Repository.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_issue(attrs),
    do: %Issue{} |> Issue.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_proposal(attrs),
    do: %Proposal{} |> Proposal.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_worker(attrs),
    do: %Worker{} |> Worker.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_agent_run(attrs),
    do: %AgentRun{} |> AgentRun.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def enqueue_agent_action(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    attrs = Map.merge(attrs, %{state: "queued", attempt_count: 0, requested_at: now})

    Multi.new()
    |> Multi.insert(:agent_action, AgentAction.changeset(%AgentAction{}, attrs))
    |> Multi.insert(:audit_event, fn %{agent_action: action} ->
      AuditEvent.changeset(%AuditEvent{}, %{
        actor: action.actor,
        action: "agent_action.queued",
        target_type: "agent_action",
        target_id: action.id,
        details: %{
          "action_key" => action.action_key,
          "prompt_version" => action.prompt_version,
          "target_type" => action.target_type,
          "target_id" => action.target_id,
          "target_label" => action.target_label
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{agent_action: action}} -> {:ok, action}
      {:error, :agent_action, changeset, _changes} -> normalize_agent_action_insert(changeset)
      {:error, _step, reason, _changes} -> {:error, reason}
    end
    |> broadcast_change()
  end

  def claim_next_agent_action(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    case next_agent_action_candidate(now) do
      nil -> {:ok, nil}
      candidate -> do_claim_agent_action(candidate, now)
    end
  end

  def next_agent_action_candidate(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    blocked_repository_ids =
      AgentAction
      |> where([action], action.state == "sync_pending")
      |> select([action], action.repository_id)
      |> distinct(true)
      |> Repo.all()

    AgentAction
    |> where(
      [action],
      action.state == "queued" and action.repository_id not in ^blocked_repository_ids and
        (is_nil(action.next_sync_attempt_at) or action.next_sync_attempt_at <= ^now)
    )
    |> order_by([action], asc: action.requested_at, asc: action.id)
    |> limit(1)
    |> preload(:repository)
    |> Repo.one()
  end

  def claim_agent_action(action_id, now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond))
      when is_integer(action_id) do
    action_id
    |> then(&Repo.get(AgentAction, &1))
    |> case do
      nil -> {:error, :agent_action_not_found}
      candidate -> do_claim_agent_action(candidate, now)
    end
  end

  def record_agent_action_baseline(action_id, issue_numbers)
      when is_integer(action_id) and is_list(issue_numbers) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated, _rows} =
      AgentAction
      |> where([action], action.id == ^action_id and action.state == "queued")
      |> Repo.update_all(
        set: [
          baseline_issue_numbers: %{"numbers" => issue_numbers},
          sync_attempt_count: 0,
          next_sync_attempt_at: nil,
          last_error: nil,
          updated_at: now
        ]
      )

    if updated == 1 do
      {:ok, AgentAction |> preload(:repository) |> Repo.get!(action_id)}
    else
      {:error, :agent_action_no_longer_queued}
    end
  end

  def record_agent_action_target_snapshot(action_id, snapshot)
      when is_integer(action_id) and is_map(snapshot) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated, _rows} =
      AgentAction
      |> where([action], action.id == ^action_id and action.state == "queued")
      |> Repo.update_all(
        set: [
          target_snapshot: snapshot,
          sync_attempt_count: 0,
          next_sync_attempt_at: nil,
          last_error: nil,
          updated_at: now
        ]
      )

    if updated == 1 do
      {:ok, AgentAction |> preload(:repository) |> Repo.get!(action_id)}
    else
      {:error, :agent_action_no_longer_queued}
    end
  end

  def fail_agent_action_preflight(action_id, reason) when is_integer(action_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = "Preflight stopped: #{bounded_error(reason)}"

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        if action.state != "queued", do: Repo.rollback(:agent_action_no_longer_queued)

        failed =
          action
          |> AgentAction.changeset(%{
            state: "failed",
            ended_at: now,
            next_sync_attempt_at: nil,
            last_error: error
          })
          |> Repo.update!()

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.preflight_failed",
          target_type: "agent_action",
          target_id: action.id,
          details: %{
            "action_key" => action.action_key,
            "error" => error
          }
        })

        failed
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, reason} -> {:error, reason}
    end
  end

  def defer_agent_action_preflight(action_id, reason) when is_integer(action_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        if action.state != "queued", do: Repo.rollback(:agent_action_no_longer_queued)

        sync_attempt_count = action.sync_attempt_count + 1

        deferred =
          action
          |> AgentAction.changeset(%{
            sync_attempt_count: sync_attempt_count,
            next_sync_attempt_at: next_sync_attempt_at(now, sync_attempt_count),
            last_error: "Preflight GitHub synchronization pending: #{bounded_error(reason)}"
          })
          |> Repo.update!()

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.preflight_deferred",
          target_type: "agent_action",
          target_id: action.id,
          details: %{
            "action_key" => action.action_key,
            "sync_attempt_count" => sync_attempt_count,
            "sync_error" => bounded_error(reason)
          }
        })

        deferred
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, reason} -> {:error, reason}
    end
  end

  def expire_agent_action_attempts(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    expired =
      AgentAction
      |> where(
        [action],
        action.state == "running" and not is_nil(action.attempt_expires_at) and
          action.attempt_expires_at <= ^now
      )
      |> Repo.all()

    count = Enum.count(expired, &expire_agent_action_attempt(&1, now))
    if count > 0, do: notify_changed(__MODULE__)
    count
  end

  def complete_agent_action(action_id, attempt_token, {:ok, result})
      when is_integer(action_id) and is_binary(attempt_token) and is_map(result) do
    finish_agent_action(action_id, attempt_token, "done", summarize_action_result(result), nil)
  end

  def complete_agent_action(action_id, attempt_token, {:error, reason})
      when is_integer(action_id) and is_binary(attempt_token) do
    finish_agent_action(action_id, attempt_token, "failed", nil, bounded_error(reason))
  end

  def next_agent_action_sync_pending(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    AgentAction
    |> where(
      [action],
      action.state == "sync_pending" and
        (is_nil(action.next_sync_attempt_at) or action.next_sync_attempt_at <= ^now)
    )
    |> order_by([action], asc: action.next_sync_attempt_at, asc: action.id)
    |> limit(1)
    |> preload(:repository)
    |> Repo.one()
  end

  def mark_agent_action_sync_pending(action_id, attempt_token, execution_result, sync_reason)
      when is_integer(action_id) and is_binary(attempt_token) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    {run_state, summary, execution_error} = agent_action_execution_fields(execution_result)
    error = sync_pending_error(execution_error, sync_reason)
    sync_attempt_count = 1

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)

        if action.state != "running" or action.attempt_token != attempt_token,
          do: Repo.rollback(:stale_agent_action_attempt)

        pending =
          action
          |> AgentAction.changeset(%{
            state: "sync_pending",
            attempt_expires_at: nil,
            sync_attempt_count: sync_attempt_count,
            next_sync_attempt_at: next_sync_attempt_at(now, sync_attempt_count),
            result_summary: summary,
            last_error: error
          })
          |> Repo.update!()

        finish_agent_action_run!(action, run_state, now)

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.sync_pending",
          target_type: "agent_action",
          target_id: action.id,
          details: %{
            "action_key" => action.action_key,
            "attempt_count" => action.attempt_count,
            "execution_state" => run_state,
            "sync_error" => bounded_error(sync_reason)
          }
        })

        pending
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_agent_action_sync(action_id, {:ok, _summary}) when is_integer(action_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        if action.state != "sync_pending", do: Repo.rollback(:agent_action_not_sync_pending)

        final_state = if is_binary(action.result_summary), do: "done", else: "failed"

        completed =
          action
          |> AgentAction.changeset(%{
            state: final_state,
            ended_at: now,
            next_sync_attempt_at: nil,
            last_error:
              if(final_state == "done", do: nil, else: execution_error_only(action.last_error))
          })
          |> Repo.update!()

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.sync_completed",
          target_type: "agent_action",
          target_id: action.id,
          details: %{"final_state" => final_state}
        })

        completed
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_agent_action_sync(action_id, {:terminal_error, reason})
      when is_integer(action_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        if action.state != "sync_pending", do: Repo.rollback(:agent_action_not_sync_pending)

        error = execution_error_only(action.last_error) || bounded_error(reason)

        completed =
          action
          |> AgentAction.changeset(%{
            state: "failed",
            ended_at: now,
            next_sync_attempt_at: nil,
            last_error: error
          })
          |> Repo.update!()

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.sync_completed",
          target_type: "agent_action",
          target_id: action.id,
          details: %{"final_state" => "failed", "terminal_error" => error}
        })

        completed
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_agent_action_sync(action_id, {:error, reason}) when is_integer(action_id) do
    action = Repo.get!(AgentAction, action_id)

    if action.state == "sync_pending" do
      sync_attempt_count = action.sync_attempt_count + 1

      action
      |> AgentAction.changeset(%{
        last_error: sync_pending_error(execution_error_only(action.last_error), reason),
        sync_attempt_count: sync_attempt_count,
        next_sync_attempt_at:
          next_sync_attempt_at(
            DateTime.utc_now() |> DateTime.truncate(:microsecond),
            sync_attempt_count
          )
      })
      |> Repo.update()
      |> broadcast_change()
    else
      {:error, :agent_action_not_sync_pending}
    end
  end

  def next_queued_job do
    Job
    |> where([job], job.state == "queued")
    |> order_by([job], asc: job.inserted_at, asc: job.id)
    |> limit(1)
    |> preload([:approval, :issue, :repository])
    |> Repo.one()
  end

  def claim_next_result_job do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    candidate =
      Job
      |> eligible_result_jobs(now)
      |> order_by([job], asc: job.result_checked_at, asc: job.inserted_at, asc: job.id)
      |> limit(1)
      |> Repo.one()

    case candidate do
      nil -> {:ok, nil}
      job -> claim_result_job(job.id, now)
    end
  end

  def claim_result_job(job_id, now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond))
      when is_integer(job_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    timeout_ms = Application.get_env(:ptc_manager, :result_claim_timeout_ms, 180_000)
    expires_at = DateTime.add(now, timeout_ms, :millisecond)

    {updated, _rows} =
      Job
      |> where([job], job.id == ^job_id)
      |> eligible_result_jobs(now)
      |> Repo.update_all(
        set: [
          state: "verifying_result",
          result_attempt_token: token,
          result_attempt_expires_at: expires_at,
          result_checked_at: now,
          updated_at: now
        ]
      )

    if updated == 1 do
      job = Job |> preload([:issue, :repository]) |> Repo.get!(job_id)
      notify_changed(__MODULE__)
      {:ok, job}
    else
      {:error, :result_already_claimed}
    end
  end

  def expire_job_leases(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    expired =
      Job
      |> where(
        [job],
        job.state in ["starting", "working", "idle", "blocked"] and
          not is_nil(job.lease_expires_at) and job.lease_expires_at <= ^now
      )
      |> Repo.all()

    count = Enum.count(expired, &expire_job_lease(&1, now))
    if count > 0, do: notify_changed(__MODULE__)
    count
  end

  def lease_job(job_id, worker_key, remote_issue, lease_ms, opts \\ [])
      when is_integer(job_id) and is_binary(worker_key) and is_map(remote_issue) and
             is_list(opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    capacity = Keyword.get(opts, :capacity, configured_agent_capacity())
    agent_kind = Keyword.get(opts, :agent_kind, configured_agent_kind())
    publication_source = configured_publication_source()

    result =
      Repo.transaction(fn ->
        job = Job |> preload([:approval, :issue, :repository]) |> Repo.get!(job_id)

        with :ok <- job_is_queued(job),
             :ok <- issue_dependency_projection_matches(Repo, job.issue, remote_issue),
             :ok <- issue_dependencies_resolved(Repo, job.issue),
             {:ok, worker} <- ensure_capacity_worker(Repo, worker_key, capacity, now),
             :ok <- dispatch_capacity_available(Repo, worker, capacity),
             {:ok, worktree_path} <- worktree_path(job.repository, job.id, job.fencing_token + 1),
             :ok <- remote_issue_matches_approval(remote_issue, job.approval) do
          fencing_token = job.fencing_token + 1
          branch_name = "ptc-manager/issue-#{job.issue.number}-job-#{job.id}"
          lease_expires_at = DateTime.add(now, lease_ms, :millisecond)

          {updated, _rows} =
            Job
            |> where(
              [candidate],
              candidate.id == ^job.id and candidate.state == "queued" and
                candidate.fencing_token == ^job.fencing_token
            )
            |> Repo.update_all(
              set: [
                state: "starting",
                fencing_token: fencing_token,
                lease_owner: worker_key,
                lease_expires_at: lease_expires_at,
                started_at: now,
                branch_name: branch_name,
                publication_source: publication_source,
                last_error: nil,
                updated_at: now
              ]
            )

          if updated == 1 do
            %WorktreeAllocation{}
            |> WorktreeAllocation.changeset(%{
              worker_id: worker.id,
              job_id: job.id,
              state: "reserved",
              path: worktree_path,
              agent_kind: agent_kind,
              last_used_at: now
            })
            |> Repo.insert!()

            leased =
              Job
              |> preload([:approval, :issue, :repository, :worktree_allocation])
              |> Repo.get!(job.id)

            insert_audit!(%{
              actor: "worker:#{worker_key}",
              action: "job.leased",
              target_type: "job",
              target_id: job.id,
              details: %{
                "fencing_token" => fencing_token,
                "branch_name" => branch_name,
                "worktree_path" => worktree_path,
                "agent_kind" => agent_kind,
                "publication_source" => publication_source,
                "lease_expires_at" => DateTime.to_iso8601(lease_expires_at)
              }
            })

            {:leased, leased}
          else
            Repo.rollback(:already_leased)
          end
        else
          {:error, :already_leased} ->
            Repo.rollback(:already_leased)

          {:error, :dispatch_capacity} ->
            Repo.rollback(:dispatch_capacity)

          {:error, :invalid_agent_capacity} ->
            Repo.rollback(:invalid_agent_capacity)

          {:error, reason} when reason in [:worker_unavailable, :worker_capacity_changed] ->
            Repo.rollback(reason)

          {:error, :worktree_root_unavailable} ->
            Repo.rollback(:worktree_root_unavailable)

          {:error, reason} ->
            rejected = reject_job!(job, reason, now)
            {:rejected, reason, rejected}
        end
      end)

    case result do
      {:ok, {:leased, job}} -> notify_and_return({:ok, job})
      {:ok, {:rejected, reason, _job}} -> notify_and_return({:error, reason})
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_job_working(job_id, fencing_token, worker_key, dispatch) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, now),
             worker <- get_or_create_dispatch_worker!(worker_key, dispatch, now) do
          working_job =
            job
            |> Job.changeset(%{state: "working", lease_expires_at: dispatch.lease_expires_at})
            |> Repo.update!()

          allocation = Repo.get_by!(WorktreeAllocation, job_id: job.id)

          allocation
          |> WorktreeAllocation.changeset(%{
            state: "active",
            herdr_workspace: dispatch.workspace_id,
            path: Map.get(dispatch, :worktree_path) || allocation.path,
            agent_kind: Map.get(dispatch, :agent_kind) || allocation.agent_kind,
            last_used_at: now,
            last_error: nil
          })
          |> Repo.update!()

          run =
            %AgentRun{}
            |> AgentRun.changeset(%{
              worker_id: worker.id,
              job_id: job.id,
              role: "implementer",
              state: "working",
              agent_name: Map.get(dispatch, :agent_name),
              status_text: "Implementing the approved issue in an isolated worktree.",
              started_at: now,
              last_heartbeat_at: now,
              herdr_workspace: dispatch.workspace_id,
              herdr_pane: dispatch.pane_id,
              herdr_session: dispatch.session,
              external_key: dispatch.external_key,
              fencing_token: fencing_token
            })
            |> Repo.insert!()

          insert_audit!(%{
            actor: "worker:#{worker_key}",
            action: "job.started",
            target_type: "job",
            target_id: job.id,
            details: %{
              "fencing_token" => fencing_token,
              "herdr_workspace" => dispatch.workspace_id,
              "herdr_pane" => dispatch.pane_id
            }
          })

          %{job: working_job, run: run}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, value} -> notify_and_return({:ok, value})
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_dispatch_failed(job_id, fencing_token, worker_key, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    message = bounded_error(reason)

    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, now) do
          failed =
            job
            |> Job.changeset(%{
              state: "failed",
              ended_at: now,
              lease_expires_at: nil,
              last_error: message
            })
            |> Repo.update!()

          mark_allocation!(job.id, %{state: "removed", removed_at: now, last_used_at: now})

          insert_audit!(%{
            actor: "worker:#{worker_key}",
            action: "job.dispatch_failed",
            target_type: "job",
            target_id: job.id,
            details: %{"fencing_token" => fencing_token, "reason" => message}
          })

          failed
        else
          {:error, failure} -> Repo.rollback(failure)
        end
      end)

    case result do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, failure} -> {:error, failure}
    end
  end

  def mark_dispatch_uncertain(job_id, fencing_token, worker_key, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    message = bounded_error(reason)

    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, now) do
          reconciling =
            job
            |> Job.changeset(%{
              state: "reconciling",
              lease_expires_at: nil,
              reconciling_at: now,
              absence_observed_at: nil,
              last_error: message
            })
            |> Repo.update!()

          mark_allocation!(job.id, %{
            state: "attention",
            last_used_at: now,
            last_error: message
          })

          insert_audit!(%{
            actor: "worker:#{worker_key}",
            action: "job.dispatch_uncertain",
            target_type: "job",
            target_id: job.id,
            details: %{"fencing_token" => fencing_token, "reason" => message}
          })

          reconciling
        else
          {:error, failure} -> Repo.rollback(failure)
        end
      end)

    case result do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, failure} -> {:error, failure}
    end
  end

  def mark_result_verified(job_id, fencing_token, attempt_token, result)
      when is_integer(job_id) and is_integer(fencing_token) and is_binary(attempt_token) and
             is_map(result) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      if valid_result_fields?(result) do
        Repo.transaction(fn ->
          {updated, _rows} =
            Job
            |> where(
              [job],
              job.id == ^job_id and job.state == "verifying_result" and
                job.fencing_token == ^fencing_token and
                job.result_attempt_token == ^attempt_token and
                not is_nil(job.result_attempt_expires_at) and
                job.result_attempt_expires_at > ^now
            )
            |> Repo.update_all(
              set: [
                state: "ready_for_pr",
                result_base_sha: result.base_sha,
                result_head_sha: result.head_sha,
                result_diff_digest: result.diff_digest,
                result_commit_count: result.commit_count,
                result_verified_at: now,
                result_attempt_expires_at: nil,
                last_error: nil,
                updated_at: now
              ]
            )

          if updated == 1 do
            job = Repo.get!(Job, job_id)

            mark_allocation!(job.id, %{
              state: "awaiting_pr",
              head_sha: result.head_sha,
              last_used_at: now,
              last_error: nil
            })

            %PrPublication{}
            |> PrPublication.changeset(%{
              job_id: job.id,
              state: "queued",
              idempotency_key: publication_key(job, result),
              fencing_token: fencing_token,
              branch_name: job.branch_name,
              base_sha: result.base_sha,
              head_sha: result.head_sha,
              diff_digest: result.diff_digest,
              attempt_count: 0,
              next_attempt_at: nil,
              source: job.publication_source || "broker"
            })
            |> Repo.insert!()

            insert_audit!(%{
              actor: "coordinator",
              action: "job.result_verified",
              target_type: "job",
              target_id: job_id,
              details: %{
                "fencing_token" => fencing_token,
                "base_sha" => result.base_sha,
                "head_sha" => result.head_sha,
                "diff_digest" => result.diff_digest,
                "commit_count" => result.commit_count
              }
            })

            job
          else
            job = Repo.get!(Job, job_id)

            if verified_result_matches?(job, fencing_token, attempt_token, result),
              do: job,
              else: Repo.rollback(result_attempt_failure(job, fencing_token, attempt_token, now))
          end
        end)
      else
        {:error, :invalid_result}
      end

    case outcome do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, reason} -> {:error, reason}
    end
  end

  def record_result_error(job_id, fencing_token, attempt_token, reason)
      when is_integer(job_id) and is_integer(fencing_token) and is_binary(attempt_token) do
    message = bounded_error(reason)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        previous = Repo.get!(Job, job_id)

        {updated, _rows} =
          Job
          |> where(
            [job],
            job.id == ^job_id and job.state == "verifying_result" and
              job.fencing_token == ^fencing_token and
              job.result_attempt_token == ^attempt_token and
              not is_nil(job.result_attempt_expires_at) and
              job.result_attempt_expires_at > ^now
          )
          |> Repo.update_all(
            set: [
              state: "awaiting_reconciliation",
              result_attempt_expires_at: nil,
              result_checked_at: now,
              last_error: message,
              updated_at: now
            ]
          )

        cond do
          updated == 1 ->
            mark_allocation!(job_id, %{
              state: "attention",
              last_used_at: now,
              last_error: message
            })

            if previous.last_error != message do
              insert_audit!(%{
                actor: "coordinator",
                action: "job.result_reconciliation_pending",
                target_type: "job",
                target_id: job_id,
                details: %{
                  "fencing_token" => fencing_token,
                  "reason" => message,
                  "observed_at" => DateTime.to_iso8601(now)
                }
              })
            end

            Repo.get!(Job, job_id)

          result_error_matches?(previous, fencing_token, attempt_token, message) ->
            previous

          true ->
            Repo.rollback(result_attempt_failure(previous, fencing_token, attempt_token, now))
        end
      end)

    case outcome do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, failure} -> {:error, failure}
    end
  end

  def dashboard_issues do
    issues =
      Issue
      |> join(:inner, [issue], repository in assoc(issue, :repository))
      |> order_by([issue], desc: issue.github_updated_at)
      |> preload([_issue, repository], repository: repository)
      |> Repo.all()

    issue_ids = Enum.map(issues, & &1.id)
    proposals = latest_proposals(issue_ids)
    jobs = active_jobs(issue_ids)
    dependencies = dashboard_dependencies(issue_ids, jobs)
    latest_jobs = latest_jobs(issue_ids)
    publications = publications_for_jobs(Map.values(jobs) ++ Map.values(latest_jobs))
    publication_ids = publications |> Map.values() |> Enum.map(& &1.id)
    pr_analyses = latest_pr_analyses(publication_ids)
    merge_approvals = latest_merge_approvals(Map.values(pr_analyses))
    agent_actions = latest_agent_actions()

    Enum.map(issues, fn issue ->
      %{
        issue: issue,
        dependencies: Map.get(dependencies, issue.id, []),
        proposal: Map.get(proposals, issue.id),
        active_job: Map.get(jobs, issue.id),
        latest_job: Map.get(latest_jobs, issue.id),
        publication:
          publication_for_issue(
            publications,
            Map.get(jobs, issue.id),
            Map.get(latest_jobs, issue.id)
          ),
        pr_analysis:
          case publication_for_issue(
                 publications,
                 Map.get(jobs, issue.id),
                 Map.get(latest_jobs, issue.id)
               ) do
            nil -> nil
            publication -> Map.get(pr_analyses, publication.id)
          end,
        merge_approval:
          case publication_for_issue(
                 publications,
                 Map.get(jobs, issue.id),
                 Map.get(latest_jobs, issue.id)
               ) do
            nil -> nil
            publication -> Map.get(merge_approvals, publication.id)
          end,
        issue_agent_action: Map.get(agent_actions, {"issue", issue.id}),
        pr_agent_action:
          case publication_for_issue(
                 publications,
                 Map.get(jobs, issue.id),
                 Map.get(latest_jobs, issue.id)
               ) do
            nil -> nil
            publication -> Map.get(agent_actions, {"pull_request", publication.id})
          end
      }
    end)
  end

  def list_agent_runs do
    AgentRun
    |> order_by([run], asc: run.started_at)
    |> preload([:worker, :agent_action, job: [:issue, :repository]])
    |> Repo.all()
  end

  def list_active_agent_runs do
    AgentRun
    |> where([run], run.state in ~w(queued starting working blocked unknown))
    |> order_by([run], asc: run.started_at, asc: run.id)
    |> preload([:worker, :agent_action, job: [:issue, :repository]])
    |> Repo.all()
  end

  def list_recent_agent_runs(limit \\ 5) when is_integer(limit) and limit > 0 do
    AgentRun
    |> where([run], run.state in ~w(done failed lost))
    |> order_by([run], desc: run.ended_at, desc: run.id)
    |> limit(^limit)
    |> preload([:worker, :agent_action, job: [:issue, :repository]])
    |> Repo.all()
  end

  def list_workers_with_worktrees do
    Worker
    |> order_by([worker], asc: worker.id)
    |> preload(worktree_allocations: [job: [:issue, :repository]])
    |> Repo.all()
  end

  def list_occupying_worktrees(worker_key) when is_binary(worker_key) do
    WorktreeAllocation
    |> join(:inner, [allocation], worker in assoc(allocation, :worker))
    |> where(
      [allocation, worker],
      worker.worker_key == ^worker_key and allocation.state != "removed"
    )
    |> order_by([allocation], asc: allocation.last_used_at, asc: allocation.id)
    |> preload([allocation, worker], worker: worker, job: [:issue, :repository])
    |> Repo.all()
  end

  def dispatch_capacity(worker_key) when is_binary(worker_key) do
    case Repo.get_by(Worker, worker_key: worker_key) do
      %Worker{status: "online", capabilities: capabilities} ->
        case capabilities["implementation_slots"] do
          capacity when is_integer(capacity) and capacity > 0 -> {:ok, capacity}
          _capacity -> {:error, :worker_has_no_implementation_capacity}
        end

      %Worker{} ->
        {:error, :worker_unavailable}

      nil ->
        {:error, :worker_unavailable}
    end
  end

  def mark_worktree_attention(allocation_id, reason, actor \\ "coordinator")
      when is_integer(allocation_id) do
    transition_worktree(allocation_id, "attention", actor, bounded_error(reason),
      from: ~w(reserved active awaiting_pr warm reclaimable attention terminal)
    )
  end

  def claim_worktree_cleanup(
        allocation_id,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      when is_integer(allocation_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    expires_at = DateTime.add(now, 300, :second)

    {updated, _rows} =
      WorktreeAllocation
      |> where(
        [allocation],
        allocation.id == ^allocation_id and
          (allocation.state in ["terminal", "reclaimable"] or
             (allocation.state == "cleaning" and allocation.cleanup_expires_at <= ^now))
      )
      |> Repo.update_all(
        set: [
          state: "cleaning",
          cleanup_token: token,
          cleanup_expires_at: expires_at,
          last_error: nil,
          updated_at: now
        ]
      )

    if updated == 1 do
      notify_changed(__MODULE__)

      claimed =
        WorktreeAllocation
        |> preload(job: [:issue, :repository])
        |> Repo.get!(allocation_id)

      {:ok, claimed, token}
    else
      {:error, :worktree_cleanup_already_claimed}
    end
  end

  def complete_worktree_cleanup(allocation_id, token)
      when is_integer(allocation_id) and is_binary(token) do
    cleanup_transition(allocation_id, token, "removed", nil)
  end

  def fail_worktree_cleanup(allocation_id, token, reason)
      when is_integer(allocation_id) and is_binary(token) do
    cleanup_transition(allocation_id, token, "attention", bounded_error(reason))
  end

  def mark_worktree_reclaimable(job_id, head_sha)
      when is_integer(job_id) and is_binary(head_sha) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      case Repo.get_by(WorktreeAllocation, job_id: job_id) do
        nil ->
          {:error, :worktree_allocation_missing}

        allocation when allocation.state in ["warm", "reclaimable"] ->
          allocation
          |> WorktreeAllocation.changeset(%{
            state: "reclaimable",
            head_sha: head_sha,
            last_used_at: now,
            last_error: nil
          })
          |> Repo.update()

        _allocation ->
          {:error, :worktree_not_warm}
      end

    broadcast_change(outcome)
  end

  def approve_issue(issue_id, actor) when is_integer(issue_id) and is_binary(actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Multi.new()
    |> Multi.run(:snapshot, fn repo, _changes -> current_approvable_snapshot(repo, issue_id) end)
    |> Multi.insert(:approval, fn %{snapshot: {issue, proposal}} ->
      Approval.changeset(%Approval{}, %{
        proposal_id: proposal.id,
        decision: "start_implementation",
        actor: actor,
        source_updated_at: issue.github_updated_at,
        source_digest: issue.content_digest,
        proposal_digest: proposal.proposal_digest,
        approved_at: now
      })
    end)
    |> Multi.insert(:job, fn %{snapshot: {issue, _proposal}, approval: approval} ->
      Job.changeset(%Job{}, %{
        repository_id: issue.repository_id,
        issue_id: issue.id,
        approval_id: approval.id,
        kind: "implementation",
        state: "queued",
        fencing_token: 0
      })
    end)
    |> Multi.insert(:audit_event, fn %{snapshot: {issue, proposal}, job: job} ->
      AuditEvent.changeset(%AuditEvent{}, %{
        actor: actor,
        action: "issue.approved_for_implementation",
        target_type: "job",
        target_id: job.id,
        details: %{
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "proposal_id" => proposal.id,
          "proposal_digest" => proposal.proposal_digest,
          "source_digest" => issue.content_digest
        }
      })
    end)
    |> Repo.transaction()
    |> normalize_approval_result()
    |> broadcast_change()
  end

  defp current_approvable_snapshot(repo, issue_id) do
    with %Issue{} = issue <- repo.get(Issue, issue_id),
         %Proposal{} = proposal <- latest_proposal(repo, issue_id),
         :ok <- issue_is_open(issue),
         :ok <- issue_workflow_allows_implementation(issue),
         :ok <- issue_dependencies_resolved(repo, issue),
         :ok <- proposal_is_ready(proposal),
         :ok <- proposal_matches_issue(proposal, issue) do
      {:ok, {issue, proposal}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp job_is_queued(%Job{state: "queued"}), do: :ok
  defp job_is_queued(%Job{}), do: {:error, :already_leased}

  defp configured_publication_source do
    if Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false),
      do: "agent",
      else: "broker"
  end

  defp dispatch_capacity_available(_repo, _worker, capacity)
       when not is_integer(capacity) or capacity < 1,
       do: {:error, :invalid_agent_capacity}

  defp dispatch_capacity_available(repo, worker, capacity) do
    allocation_count =
      WorktreeAllocation
      |> where(
        [allocation],
        allocation.worker_id == ^worker.id and allocation.state != "removed"
      )
      |> repo.aggregate(:count)

    legacy_count =
      from(job in Job,
        as: :job,
        where:
          job.lease_owner == ^worker.worker_key and job.state in ^@capacity_job_states and
            not exists(
              from allocation in WorktreeAllocation,
                where: allocation.job_id == parent_as(:job).id
            )
      )
      |> repo.aggregate(:count)

    if allocation_count + legacy_count < capacity,
      do: :ok,
      else: {:error, :dispatch_capacity}
  end

  defp ensure_capacity_worker(_repo, _worker_key, capacity, _now)
       when not is_integer(capacity) or capacity < 1,
       do: {:error, :invalid_agent_capacity}

  defp ensure_capacity_worker(repo, worker_key, capacity, now) do
    attrs = %{
      worker_key: worker_key,
      name: "Herdr #{String.replace_prefix(worker_key, "herdr:", "")}",
      status: "online",
      capabilities: %{
        "herdr" => true,
        "dispatch" => true,
        "implementation_slots" => capacity
      },
      last_heartbeat_at: now
    }

    case repo.get_by(Worker, worker_key: worker_key) do
      nil ->
        {:ok, %Worker{} |> Worker.changeset(attrs) |> repo.insert!()}

      %Worker{status: "online", capabilities: capabilities} = worker ->
        if capabilities["implementation_slots"] == capacity,
          do: {:ok, worker},
          else: {:error, :worker_capacity_changed}

      %Worker{} ->
        {:error, :worker_unavailable}
    end
  end

  defp worktree_path(repository, job_id, fencing_token) do
    repository_path = Application.get_env(:ptc_manager, :repository_path) || repository.local_path

    root =
      Application.get_env(:ptc_manager, :worktree_root) ||
        if(is_binary(repository_path),
          do: Path.join(Path.dirname(Path.expand(repository_path)), ".ptc-manager-worktrees")
        )

    if is_binary(root) and Path.type(root) == :absolute do
      slug =
        "#{repository.github_owner}-#{repository.github_name}"
        |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")

      {:ok, Path.join(Path.expand(root), "#{slug}-job-#{job_id}-f#{fencing_token}")}
    else
      {:error, :worktree_root_unavailable}
    end
  end

  defp remote_issue_matches_approval(remote, approval) do
    cond do
      remote.state != "open" ->
        {:error, :issue_closed}

      remote.content_digest != approval.source_digest ->
        {:error, :stale_approval}

      DateTime.compare(remote.github_updated_at, approval.source_updated_at) != :eq ->
        {:error, :stale_approval}

      true ->
        :ok
    end
  end

  defp reject_job!(job, reason, now) do
    {updated, _rows} =
      Job
      |> where(
        [candidate],
        candidate.id == ^job.id and candidate.state == "queued" and
          candidate.fencing_token == ^job.fencing_token
      )
      |> Repo.update_all(
        set: [state: "cancelled", ended_at: now, last_error: to_string(reason), updated_at: now]
      )

    if updated == 1 do
      insert_audit!(%{
        actor: "coordinator",
        action: "job.dispatch_rejected",
        target_type: "job",
        target_id: job.id,
        details: %{"reason" => to_string(reason)}
      })

      Repo.get!(Job, job.id)
    else
      Repo.rollback(:already_leased)
    end
  end

  defp valid_lease(job, fencing_token, worker_key, now) do
    cond do
      job.state != "starting" -> {:error, :invalid_job_state}
      job.fencing_token != fencing_token -> {:error, :stale_fencing_token}
      job.lease_owner != worker_key -> {:error, :wrong_lease_owner}
      is_nil(job.lease_expires_at) -> {:error, :lease_expired}
      DateTime.compare(job.lease_expires_at, now) == :lt -> {:error, :lease_expired}
      true -> :ok
    end
  end

  defp valid_result_attempt(job, fencing_token, attempt_token, now) do
    cond do
      job.state != "verifying_result" ->
        {:error, :invalid_job_state}

      job.fencing_token != fencing_token ->
        {:error, :stale_fencing_token}

      job.result_attempt_token != attempt_token ->
        {:error, :stale_result_attempt}

      not is_binary(job.branch_name) ->
        {:error, :missing_branch}

      is_nil(job.result_attempt_expires_at) ->
        {:error, :result_claim_expired}

      DateTime.compare(job.result_attempt_expires_at, now) != :gt ->
        {:error, :result_claim_expired}

      true ->
        :ok
    end
  end

  defp verified_result_matches?(job, fencing_token, attempt_token, result) do
    job.state == "ready_for_pr" and job.fencing_token == fencing_token and
      job.result_attempt_token == attempt_token and job.result_base_sha == result.base_sha and
      job.result_head_sha == result.head_sha and
      job.result_diff_digest == result.diff_digest and
      job.result_commit_count == result.commit_count
  end

  defp result_error_matches?(job, fencing_token, attempt_token, message) do
    job.state == "awaiting_reconciliation" and job.fencing_token == fencing_token and
      job.result_attempt_token == attempt_token and job.last_error == message
  end

  defp result_attempt_failure(job, fencing_token, attempt_token, now) do
    case valid_result_attempt(job, fencing_token, attempt_token, now) do
      :ok -> :result_race
      {:error, reason} -> reason
    end
  end

  defp valid_result_fields?(result) do
    sha = ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

    is_binary(result[:base_sha]) and Regex.match?(sha, result.base_sha) and
      is_binary(result[:head_sha]) and Regex.match?(sha, result.head_sha) and
      is_binary(result[:diff_digest]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, result.diff_digest) and
      is_integer(result[:commit_count]) and result.commit_count > 0
  end

  defp eligible_result_jobs(query, now) do
    where(
      query,
      [job],
      job.state == "awaiting_reconciliation" or
        (job.state == "verifying_result" and not is_nil(job.result_attempt_expires_at) and
           job.result_attempt_expires_at <= ^now)
    )
  end

  defp publication_key(job, result) do
    "#{job.id}:#{job.fencing_token}:#{job.branch_name}:#{result.head_sha}:#{result.diff_digest}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp publications_for_jobs(jobs) do
    job_ids = jobs |> Enum.reject(&is_nil/1) |> Enum.map(& &1.id) |> Enum.uniq()

    case job_ids do
      [] ->
        %{}

      ids ->
        PrPublication
        |> where([publication], publication.job_id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.job_id, &1})
    end
  end

  defp publication_for_issue(publications, active_job, latest_job) do
    job = active_job || latest_job
    if job, do: Map.get(publications, job.id)
  end

  defp latest_agent_actions do
    AgentAction
    |> order_by([action], desc: action.inserted_at, desc: action.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn action, actions ->
      Map.put_new(actions, {action.target_type, action.target_id}, action)
    end)
  end

  defp latest_pr_analyses([]), do: %{}

  defp latest_pr_analyses(publication_ids) do
    PrAnalysis
    |> where([analysis], analysis.publication_id in ^publication_ids)
    |> order_by([analysis], desc: analysis.analyzed_at, desc: analysis.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn analysis, analyses ->
      Map.put_new(analyses, analysis.publication_id, analysis)
    end)
  end

  defp latest_merge_approvals([]), do: %{}

  defp latest_merge_approvals(pr_analyses) do
    analysis_ids = Enum.map(pr_analyses, & &1.id)

    MergeApproval
    |> where([approval], approval.pr_analysis_id in ^analysis_ids)
    |> order_by([approval], desc: approval.approved_at, desc: approval.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn approval, approvals ->
      Map.put_new(approvals, approval.publication_id, approval)
    end)
  end

  defp do_claim_agent_action(candidate, now) do
    timeout_ms = Application.get_env(:ptc_manager, :agent_action_timeout_ms, 1_800_000)
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    expires_at = DateTime.add(now, timeout_ms, :millisecond)
    attempt_count = candidate.attempt_count + 1

    outcome =
      Repo.transaction(fn ->
        {updated, _rows} =
          AgentAction
          |> where(
            [action],
            action.id == ^candidate.id and action.attempt_count == ^candidate.attempt_count and
              action.state == "queued"
          )
          |> Repo.update_all(
            set: [
              state: "running",
              attempt_count: attempt_count,
              attempt_token: token,
              attempt_expires_at: expires_at,
              started_at: now,
              ended_at: nil,
              result_summary: nil,
              last_error: nil,
              updated_at: now
            ]
          )

        if updated != 1, do: Repo.rollback(:agent_action_already_claimed)

        AgentRun
        |> where(
          [run],
          run.agent_action_id == ^candidate.id and
            run.state in ["queued", "starting", "working", "idle", "blocked", "unknown"]
        )
        |> Repo.update_all(
          set: [
            state: "lost",
            status_text: "The previous action attempt expired before reporting a result.",
            ended_at: now,
            last_heartbeat_at: now,
            updated_at: now
          ]
        )

        worker = get_or_create_agent_action_worker!(now)

        %AgentRun{}
        |> AgentRun.changeset(%{
          worker_id: worker.id,
          agent_action_id: candidate.id,
          role: "manager",
          state: "working",
          status_text: "Running #{candidate.action_key |> String.replace("_", " ")}.",
          started_at: now,
          last_heartbeat_at: now,
          fencing_token: attempt_count
        })
        |> Repo.insert!()

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.started",
          target_type: "agent_action",
          target_id: candidate.id,
          details: %{
            "action_key" => candidate.action_key,
            "attempt_count" => attempt_count,
            "attempt_expires_at" => DateTime.to_iso8601(expires_at)
          }
        })

        AgentAction |> preload(:repository) |> Repo.get!(candidate.id)
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, {action, token}})
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire_agent_action_attempt(action, now) do
    outcome =
      Repo.transaction(fn ->
        message =
          "The agent stopped reporting before the deadline; GitHub may contain partial changes. Inspect it before queuing another action."

        {updated, _rows} =
          AgentAction
          |> where(
            [candidate],
            candidate.id == ^action.id and candidate.state == "running" and
              candidate.attempt_token == ^action.attempt_token and
              candidate.attempt_expires_at <= ^now
          )
          |> Repo.update_all(
            set: [
              state: "sync_pending",
              ended_at: nil,
              attempt_expires_at: nil,
              sync_attempt_count: 0,
              next_sync_attempt_at: now,
              last_error: "Execution failed: #{message}",
              updated_at: now
            ]
          )

        if updated != 1, do: Repo.rollback(:agent_action_no_longer_expired)

        AgentRun
        |> where(
          [run],
          run.agent_action_id == ^action.id and run.fencing_token == ^action.attempt_count and
            run.state in ["queued", "starting", "working", "idle", "blocked", "unknown"]
        )
        |> Repo.update_all(
          set: [
            state: "lost",
            status_text: "The action deadline passed with an unknown GitHub outcome.",
            last_heartbeat_at: now,
            ended_at: now,
            updated_at: now
          ]
        )

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.expired",
          target_type: "agent_action",
          target_id: action.id,
          details: %{
            "action_key" => action.action_key,
            "attempt_count" => action.attempt_count,
            "outcome" => "unknown"
          }
        })

        true
      end)

    match?({:ok, true}, outcome)
  end

  defp finish_agent_action(action_id, token, state, summary, error) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)

        if action.state != "running" or action.attempt_token != token,
          do: Repo.rollback(:stale_agent_action_attempt)

        completed =
          action
          |> AgentAction.changeset(%{
            state: state,
            ended_at: now,
            attempt_expires_at: nil,
            result_summary: summary,
            last_error: error
          })
          |> Repo.update!()

        run =
          AgentRun
          |> where(
            [run],
            run.agent_action_id == ^action.id and run.fencing_token == ^action.attempt_count
          )
          |> order_by([run], desc: run.id)
          |> limit(1)
          |> Repo.one!()

        run
        |> AgentRun.changeset(%{
          state: state,
          status_text:
            if(state == "done",
              do: "Completed #{action.action_key |> String.replace("_", " ")}.",
              else: "The action failed; details are retained in PtcManager."
            ),
          last_heartbeat_at: now,
          ended_at: now
        })
        |> Repo.update!()

        insert_audit!(%{
          actor: "coordinator",
          action: "agent_action.#{state}",
          target_type: "agent_action",
          target_id: action.id,
          details: %{
            "action_key" => action.action_key,
            "attempt_count" => action.attempt_count,
            "error" => error
          }
        })

        completed
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_agent_action_run!(action, state, now) do
    run =
      AgentRun
      |> where(
        [run],
        run.agent_action_id == ^action.id and run.fencing_token == ^action.attempt_count
      )
      |> order_by([run], desc: run.id)
      |> limit(1)
      |> Repo.one!()

    run
    |> AgentRun.changeset(%{
      state: state,
      status_text:
        if(state == "done",
          do: "Completed #{action.action_key |> String.replace("_", " ")}.",
          else: "The action failed; GitHub reconciliation is still required."
        ),
      last_heartbeat_at: now,
      ended_at: now
    })
    |> Repo.update!()
  end

  defp agent_action_execution_fields({:ok, result}) when is_map(result),
    do: {"done", summarize_action_result(result), nil}

  defp agent_action_execution_fields({:error, reason}),
    do: {"failed", nil, "Execution failed: #{bounded_error(reason)}"}

  defp sync_pending_error(execution_error, sync_reason) do
    [execution_error, "GitHub synchronization pending: #{bounded_error(sync_reason)}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> String.slice(0, 1_000)
  end

  defp execution_error_only(error) when is_binary(error) do
    error
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "Execution failed:"))
  end

  defp execution_error_only(_error), do: nil

  defp next_sync_attempt_at(now, attempt_count) do
    base = Application.get_env(:ptc_manager, :agent_action_sync_retry_base_ms, 5_000)
    maximum = Application.get_env(:ptc_manager, :agent_action_sync_retry_max_ms, 300_000)
    exponent = min(max(attempt_count - 1, 0), 20)
    delay = min(round(base * :math.pow(2, exponent)), maximum)
    DateTime.add(now, delay, :millisecond)
  end

  defp get_or_create_agent_action_worker!(now) do
    attrs = %{
      worker_key: "agent-actions:local",
      name: "PtcManager maintainer",
      status: "online",
      capabilities: %{"codex" => true, "github_actions" => true},
      last_heartbeat_at: now
    }

    case Repo.get_by(Worker, worker_key: attrs.worker_key) do
      nil -> %Worker{} |> Worker.changeset(attrs) |> Repo.insert!()
      worker -> worker |> Worker.changeset(attrs) |> Repo.update!()
    end
  end

  defp summarize_action_result(result), do: Jason.encode!(result)

  defp normalize_agent_action_insert(changeset) do
    if changeset.errors[:action_key],
      do: {:error, :agent_action_already_active},
      else: {:error, changeset}
  end

  defp get_or_create_dispatch_worker!(worker_key, dispatch, now) do
    case Repo.get_by(Worker, worker_key: worker_key) do
      nil ->
        capacity = configured_agent_capacity()

        %Worker{}
        |> Worker.changeset(%{
          worker_key: worker_key,
          name: "Herdr #{dispatch.session}",
          status: "online",
          capabilities: %{
            "herdr" => true,
            "dispatch" => true,
            "implementation_slots" => capacity
          },
          last_heartbeat_at: now
        })
        |> Repo.insert!()

      worker ->
        worker
    end
  end

  defp mark_allocation!(job_id, attrs) do
    case Repo.get_by(WorktreeAllocation, job_id: job_id) do
      nil -> nil
      allocation -> allocation |> WorktreeAllocation.changeset(attrs) |> Repo.update!()
    end
  end

  defp transition_worktree(allocation_id, state, actor, error, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        allocation = Repo.get!(WorktreeAllocation, allocation_id)
        allowed_from = Keyword.get(opts, :from)

        if allowed_from && allocation.state not in allowed_from,
          do: Repo.rollback(:invalid_worktree_transition)

        attrs = %{
          state: state,
          last_used_at: now,
          last_error: error,
          removed_at: if(state == "removed", do: now)
        }

        updated = allocation |> WorktreeAllocation.changeset(attrs) |> Repo.update!()

        insert_audit!(%{
          actor: actor,
          action: "worktree.#{state}",
          target_type: "worktree_allocation",
          target_id: allocation.id,
          details: %{
            "job_id" => allocation.job_id,
            "reason" => error
          }
        })

        updated
      end)

    broadcast_change(outcome)
  end

  defp cleanup_transition(allocation_id, token, state, error) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {updated, _rows} =
      WorktreeAllocation
      |> where(
        [allocation],
        allocation.id == ^allocation_id and allocation.state == "cleaning" and
          allocation.cleanup_token == ^token
      )
      |> Repo.update_all(
        set: [
          state: state,
          last_used_at: now,
          last_error: error,
          removed_at: if(state == "removed", do: now),
          cleanup_token: nil,
          cleanup_expires_at: nil,
          updated_at: now
        ]
      )

    if updated == 1 do
      notify_changed(__MODULE__)
      {:ok, Repo.get!(WorktreeAllocation, allocation_id)}
    else
      {:error, :stale_worktree_cleanup_claim}
    end
  end

  defp expire_job_lease(job, now) do
    Repo.transaction(fn ->
      {updated, _rows} =
        Job
        |> where(
          [candidate],
          candidate.id == ^job.id and candidate.fencing_token == ^job.fencing_token and
            candidate.state in ["starting", "working", "idle", "blocked"] and
            candidate.lease_expires_at <= ^now
        )
        |> Repo.update_all(
          set: [
            state: "reconciling",
            lease_expires_at: nil,
            reconciling_at: now,
            absence_observed_at: nil,
            last_error: "The worker lease expired; remote activity must be reconciled.",
            updated_at: now
          ]
        )

      if updated == 1 do
        mark_allocation!(job.id, %{
          state: "attention",
          last_used_at: now,
          last_error: "The worker lease expired; remote activity must be reconciled."
        })

        insert_audit!(%{
          actor: "coordinator",
          action: "job.lease_reconciliation_required",
          target_type: "job",
          target_id: job.id,
          details: %{"fencing_token" => job.fencing_token}
        })

        true
      else
        false
      end
    end)
    |> case do
      {:ok, expired?} -> expired?
      {:error, _reason} -> false
    end
  end

  defp insert_audit!(attrs), do: %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert!()
  defp bounded_error(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 500)

  defp configured_agent_capacity,
    do: Application.get_env(:ptc_manager, :implementation_agent_capacity, 1)

  defp configured_agent_kind,
    do: Application.get_env(:ptc_manager, :implementation_agent_kind, "codex")

  defp notify_and_return(result) do
    notify_changed(__MODULE__)
    result
  end

  defp issue_is_open(%Issue{state: "open"}), do: :ok
  defp issue_is_open(%Issue{}), do: {:error, :issue_closed}

  defp issue_workflow_allows_implementation(%Issue{
         workflow_label_conflict: false,
         workflow_label: label
       })
       when label in [nil, "ptc:ready"],
       do: :ok

  defp issue_workflow_allows_implementation(%Issue{}),
    do: {:error, :issue_workflow_not_ready}

  defp issue_dependencies_resolved(_repo, %Issue{dependencies_projected: false}),
    do: {:error, :issue_dependencies_unresolved}

  defp issue_dependencies_resolved(_repo, %Issue{dependency_overflow: true}),
    do: {:error, :issue_dependencies_unresolved}

  defp issue_dependencies_resolved(repo, %Issue{} = issue) do
    unresolved_count =
      IssueDependency
      |> where([dependency], dependency.issue_id == ^issue.id)
      |> join(:left, [dependency], blocker in Issue,
        on: blocker.id == dependency.blocking_issue_id
      )
      |> where([_dependency, blocker], is_nil(blocker.id) or blocker.state != "closed")
      |> repo.aggregate(:count)

    if unresolved_count == 0, do: :ok, else: {:error, :issue_dependencies_unresolved}
  end

  defp issue_dependency_projection_matches(
         _repo,
         %Issue{dependencies_projected: false},
         _remote
       ),
       do: {:error, :issue_dependencies_unresolved}

  defp issue_dependency_projection_matches(_repo, _issue, %{dependency_overflow: true}),
    do: {:error, :issue_dependencies_unresolved}

  defp issue_dependency_projection_matches(repo, issue, remote) do
    projected_numbers =
      IssueDependency
      |> where([dependency], dependency.issue_id == ^issue.id)
      |> order_by([dependency], asc: dependency.blocking_issue_number)
      |> select([dependency], dependency.blocking_issue_number)
      |> repo.all()

    if projected_numbers == remote.blocking_issue_numbers,
      do: :ok,
      else: {:error, :issue_dependencies_unresolved}
  end

  defp proposal_is_ready(%Proposal{readiness: "ready"}), do: :ok
  defp proposal_is_ready(%Proposal{}), do: {:error, :proposal_not_ready}

  defp proposal_matches_issue(proposal, issue) do
    if proposal.source_digest == issue.content_digest and
         DateTime.compare(proposal.source_updated_at, issue.github_updated_at) == :eq do
      :ok
    else
      {:error, :stale_proposal}
    end
  end

  defp latest_proposal(repo, issue_id) do
    Proposal
    |> where([proposal], proposal.issue_id == ^issue_id)
    |> order_by([proposal], desc: proposal.inserted_at, desc: proposal.id)
    |> limit(1)
    |> repo.one()
  end

  defp latest_proposals([]), do: %{}

  defp latest_proposals(issue_ids) do
    Proposal
    |> where([proposal], proposal.issue_id in ^issue_ids)
    |> order_by([proposal], desc: proposal.inserted_at, desc: proposal.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn proposal, proposals ->
      Map.put_new(proposals, proposal.issue_id, proposal)
    end)
  end

  defp active_jobs([]), do: %{}

  defp active_jobs(issue_ids) do
    Job
    |> where(
      [job],
      job.issue_id in ^issue_ids and job.state in ^@active_job_states
    )
    |> order_by([job], desc: job.inserted_at)
    |> Repo.all()
    |> Map.new(&{&1.issue_id, &1})
  end

  defp dashboard_dependencies([], _jobs), do: %{}

  defp dashboard_dependencies(issue_ids, jobs) do
    IssueDependency
    |> where([dependency], dependency.issue_id in ^issue_ids)
    |> order_by([dependency], asc: dependency.blocking_issue_number)
    |> preload(:blocking_issue)
    |> Repo.all()
    |> Enum.group_by(& &1.issue_id, fn dependency ->
      %{
        number: dependency.blocking_issue_number,
        issue: dependency.blocking_issue,
        active_job: dependency.blocking_issue && Map.get(jobs, dependency.blocking_issue.id)
      }
    end)
  end

  defp latest_jobs([]), do: %{}

  defp latest_jobs(issue_ids) do
    Job
    |> where([job], job.issue_id in ^issue_ids)
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn job, jobs -> Map.put_new(jobs, job.issue_id, job) end)
  end

  defp normalize_approval_result({:ok, %{job: job}}), do: {:ok, job}
  defp normalize_approval_result({:error, :snapshot, reason, _changes}), do: {:error, reason}

  defp normalize_approval_result({:error, :job, changeset, _changes}) do
    if changeset.errors[:issue_id] do
      {:error, :already_active}
    else
      {:error, changeset}
    end
  end

  defp normalize_approval_result({:error, _step, reason, _changes}), do: {:error, reason}

  defp broadcast_change({:ok, record} = result) do
    notify_changed(record.__struct__)
    result
  end

  defp broadcast_change(result), do: result
end
