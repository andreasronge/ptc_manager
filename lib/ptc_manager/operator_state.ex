defmodule PtcManager.OperatorState do
  @moduledoc """
  The console's state as a program reads it: one JSON-ready projection of the
  records a monitoring agent otherwise had to query by hand.

  Every value comes from an existing context function or a bounded query, and
  nothing here writes. No schema struct is encoded whole: each record is
  projected field by field, and the fields an agent may have written (stop
  reports, findings, error text, action results, audit details, status text)
  sit under an `untrusted` key so a reader cannot mistake them for the
  console's own words. `PLAN.md`: model output is data, never authority.
  """

  import Ecto.Query

  alias PtcManager.{CapacitySettings, Collections, Deployments, OperationalMode, Repo, Reviews}
  alias PtcManager.{ResourceOperations, Stalls}
  alias PtcManager.Collections.Run
  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AgentAction,
    AgentHealth,
    AuditEvent,
    Job,
    PrPublication,
    Repository
  }

  @recent_ms 86_400_000
  @recent_steps 5
  @recent_audit_events 50
  @pending_action_states ~w(queued running sync_pending)
  @open_review_states ~w(running paused manual changes_requested resume_pending)

  @doc "The whole projection, per enabled repository plus the console-wide sections."
  def snapshot(now \\ DateTime.utc_now()) do
    Map.merge(envelope(now), %{
      operational_mode: mode_name(OperationalMode.mode()),
      deployments: Enum.map(Deployments.active(), &deployment/1),
      capacity: capacity(now),
      resource_operations:
        ResourceOperations.list_current()
        |> Enum.filter(& &1.slot_number)
        |> Enum.map(&resource_operation/1),
      workers: Enum.map(Operations.list_workers(), &worker(&1, now)),
      agent_runs:
        (Operations.list_active_agent_runs() ++ Operations.list_waiting_agent_runs())
        |> Enum.map(&agent_run(&1, now)),
      audit_events: Enum.map(recent_audit_events(), &audit_event/1),
      repositories: Enum.map(enabled_repositories(), &repository(&1, now))
    })
  end

  @doc "`PtcManager.Stalls.detect/1` with the console's words under `untrusted`, since they quote agent text."
  def stalls(now \\ DateTime.utc_now()) do
    Map.put(envelope(now), :stalls, Enum.map(Stalls.detect(now), &stall/1))
  end

  defp envelope(now) do
    %{captured_at: now, deployed_sha: Application.get_env(:ptc_manager, :deployed_sha)}
  end

  ## Console-wide sections

  defp mode_name({:canary, _invocation_id}), do: "canary"
  defp mode_name(mode) when is_atom(mode), do: Atom.to_string(mode)

  defp deployment(deployment) do
    %{
      id: deployment.id,
      repository_id: deployment.repository_id,
      state: deployment.state,
      requested_sha: deployment.requested_sha,
      requested_by: deployment.requested_by,
      requested_at: deployment.requested_at,
      started_at: deployment.started_at,
      untrusted: %{status_text: deployment.status_text, last_error: deployment.last_error}
    }
  end

  defp capacity(now) do
    settings = CapacitySettings.current()
    usage = Operations.agent_slot_usage(now)

    %{
      light_agent_capacity: settings.light_agent_capacity,
      heavy_agent_capacity: settings.heavy_agent_capacity,
      operation_capacity: settings.operation_capacity,
      light_agents_in_use: usage.light,
      heavy_agents_in_use: usage.heavy,
      operations_in_use: ResourceOperations.count_active(),
      herdr_online: usage.herdr_online?
    }
  end

  defp resource_operation(operation) do
    %{
      id: operation.id,
      repository_id: operation.repository_id,
      job_id: operation.job_id,
      agent_action_id: operation.agent_action_id,
      agent_run_id: operation.agent_run_id,
      label: operation.label,
      state: operation.state,
      slot_number: operation.slot_number,
      wrapper_pid: operation.wrapper_pid,
      queued_at: operation.queued_at,
      started_at: operation.started_at,
      last_heartbeat_at: operation.last_heartbeat_at,
      untrusted: %{last_error: operation.last_error}
    }
  end

  defp worker(worker, now) do
    %{
      id: worker.id,
      key: worker.worker_key,
      name: worker.name,
      status: worker.status,
      online: Operations.herdr_worker_online?(worker, now),
      last_heartbeat_at: worker.last_heartbeat_at,
      agent_kinds: get_in(worker.capabilities, ["agent_kinds"]) || []
    }
  end

  defp agent_run(run, now) do
    health = AgentHealth.assess(run, now)

    %{
      id: run.id,
      role: run.role,
      state: run.state,
      job_id: run.job_id,
      agent_action_id: run.agent_action_id,
      worker_id: run.worker_id,
      agent_name: run.agent_name,
      herdr_pane: run.herdr_pane,
      started_at: run.started_at,
      last_heartbeat_at: run.last_heartbeat_at,
      state_changed_at: run.state_changed_at,
      health: %{status: health.status, label: health.label, detail: health.detail},
      untrusted: %{status_text: run.status_text}
    }
  end

  defp recent_audit_events do
    Repo.all(
      from event in AuditEvent,
        order_by: [desc: event.inserted_at, desc: event.id],
        limit: @recent_audit_events
    )
  end

  defp audit_event(event) do
    %{
      id: event.id,
      actor: event.actor,
      action: event.action,
      target_type: event.target_type,
      target_id: event.target_id,
      at: event.inserted_at,
      untrusted: %{details: event.details}
    }
  end

  ## Per repository

  defp enabled_repositories, do: Enum.filter(Operations.list_repositories(), & &1.enabled)

  defp repository(%Repository{} = repository, now) do
    %{
      id: repository.id,
      owner: repository.github_owner,
      name: repository.github_name,
      default_branch: repository.default_branch,
      collection_runs: Enum.map(live_runs(repository), &collection_run/1),
      jobs: Enum.map(jobs(repository, now), &job/1),
      agent_actions: Enum.map(pending_actions(repository), &agent_action/1),
      review_rounds: review_rounds(repository),
      publications: Enum.map(open_publications(repository), &publication/1)
    }
  end

  defp live_runs(repository) do
    Repo.all(
      from run in Run,
        where: run.repository_id == ^repository.id and run.state in ^Run.live_states(),
        order_by: [asc: run.id],
        preload: [:issue, :steps, :members]
    )
  end

  defp collection_run(%Run{} = run) do
    %{
      id: run.id,
      issue_id: run.issue_id,
      issue_number: run.issue.number,
      state: run.state,
      auto_merge: run.auto_merge,
      auto_recover: run.auto_recover,
      started_at: run.started_at,
      paused_at: run.paused_at,
      pause_kind: run.pause_kind,
      paused_issue_number: run.paused_issue_number,
      escalation_pending: run.escalation_pending,
      members: Enum.map(Collections.member_statuses(run), &member_status/1),
      steps:
        run.steps
        |> Enum.sort_by(& &1.id, :desc)
        |> Enum.take(@recent_steps)
        |> Enum.map(&step/1),
      untrusted: %{pause_reason: run.pause_reason}
    }
  end

  defp member_status(status) do
    %{
      number: status.number,
      issue_id: status.issue && status.issue.id,
      status: status.status,
      job_id: status.job && status.job.id,
      publication_id: status.publication && status.publication.id,
      attention_kind: status.attention && status.attention[:kind],
      untrusted: %{attention_reason: status.attention && status.attention[:reason]}
    }
  end

  defp step(step) do
    %{kind: step.kind, scope: step.scope, actor: step.actor, at: step.inserted_at}
  end

  defp jobs(repository, now) do
    ended_after = DateTime.add(now, -@recent_ms, :millisecond)

    Repo.all(
      from job in Job,
        where:
          job.repository_id == ^repository.id and
            (job.state in ^Job.live_states() or job.ended_at >= ^ended_after),
        order_by: [desc: job.id],
        preload: [:issue]
    )
  end

  defp job(%Job{} = job) do
    %{
      id: job.id,
      issue_id: job.issue_id,
      issue_number: job.issue.number,
      state: job.state,
      review_state: job.review_state,
      review_generation: job.review_generation,
      required_review_count: job.required_review_count,
      reviewed_head_sha: job.reviewed_head_sha,
      result_head_sha: job.result_head_sha,
      started_at: job.started_at,
      ended_at: job.ended_at,
      stop_reported_at: job.stop_reported_at,
      stop_acknowledged_at: job.stop_acknowledged_at,
      cancellation_reason: job.cancellation_reason,
      untrusted: %{last_error: job.last_error, stop_report: job.stop_report}
    }
  end

  defp pending_actions(repository) do
    Repo.all(
      from action in AgentAction,
        where: action.repository_id == ^repository.id and action.state in @pending_action_states,
        order_by: [asc: action.id]
    )
  end

  defp agent_action(%AgentAction{} = action) do
    %{
      id: action.id,
      action_key: action.action_key,
      target_type: action.target_type,
      target_id: action.target_id,
      state: action.state,
      actor: action.actor,
      attempt_count: action.attempt_count,
      requested_at: action.requested_at,
      started_at: action.started_at,
      untrusted: %{target_label: action.target_label, last_error: action.last_error}
    }
  end

  defp review_rounds(repository) do
    jobs =
      Repo.all(
        from job in Job,
          where:
            job.repository_id == ^repository.id and job.review_state in @open_review_states and
              job.state in ^Reviews.active_states(),
          select: job.id
      )

    for job_id <- jobs, round <- Reviews.rounds(job_id) do
      %{
        job_id: round.job_id,
        number: round.number,
        generation: round.generation,
        state: round.state,
        head_sha: round.head_sha,
        updated_at: round.updated_at,
        expires_at: round.expires_at,
        untrusted: %{
          error: round.error,
          failure: round.failure,
          findings: round.result && round.result["findings"]
        }
      }
    end
  end

  defp open_publications(repository) do
    Repo.all(
      from publication in PrPublication,
        where:
          publication.repository_id == ^repository.id and
            publication.state in ["published", "blocked"] and
            publication.pr_state == "open",
        order_by: [asc: publication.id]
    )
  end

  defp publication(%PrPublication{} = publication) do
    %{
      id: publication.id,
      job_id: publication.job_id,
      pr_number: publication.pr_number,
      pr_url: publication.pr_url,
      state: publication.state,
      pr_state: publication.pr_state,
      source: publication.source,
      checks_state: publication.checks_state,
      mergeability: publication.mergeability,
      head_sha: publication.head_sha,
      remote_head_sha: publication.remote_head_sha,
      head_drifted: publication.head_sha != publication.remote_head_sha,
      pr_checked_at: publication.pr_checked_at,
      untrusted: %{title: publication.title, last_error: publication.last_error}
    }
  end

  ## Stalls

  defp stall(stall) do
    %{
      kind: stall.kind,
      severity: stall.severity,
      target_type: stall.target_type,
      target_id: stall.target_id,
      repository_id: stall.repository_id,
      issue_id: stall.issue_id,
      since: stall.since,
      untrusted: %{detail: stall.detail}
    }
  end
end
