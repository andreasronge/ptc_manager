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
    AgentRun,
    Approval,
    AuditEvent,
    Issue,
    Job,
    Proposal,
    Repository,
    Worker
  }

  @active_job_states ~w(queued starting working idle blocked reconciling awaiting_reconciliation)
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

  def next_queued_job do
    Job
    |> where([job], job.state == "queued")
    |> order_by([job], asc: job.inserted_at, asc: job.id)
    |> limit(1)
    |> preload([:approval, :issue, :repository])
    |> Repo.one()
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

  def lease_job(job_id, worker_key, remote_issue, lease_ms)
      when is_integer(job_id) and is_binary(worker_key) and is_map(remote_issue) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        job = Job |> preload([:approval, :issue, :repository]) |> Repo.get!(job_id)

        with :ok <- job_is_queued(job),
             :ok <- dispatch_capacity_available(Repo),
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
                last_error: nil,
                updated_at: now
              ]
            )

          if updated == 1 do
            leased = Job |> preload([:approval, :issue, :repository]) |> Repo.get!(job.id)

            insert_audit!(%{
              actor: "worker:#{worker_key}",
              action: "job.leased",
              target_type: "job",
              target_id: job.id,
              details: %{
                "fencing_token" => fencing_token,
                "branch_name" => branch_name,
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

          run =
            %AgentRun{}
            |> AgentRun.changeset(%{
              worker_id: worker.id,
              job_id: job.id,
              role: "implementer",
              state: "working",
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
    latest_jobs = latest_jobs(issue_ids)

    Enum.map(issues, fn issue ->
      %{
        issue: issue,
        proposal: Map.get(proposals, issue.id),
        active_job: Map.get(jobs, issue.id),
        latest_job: Map.get(latest_jobs, issue.id)
      }
    end)
  end

  def list_agent_runs do
    AgentRun
    |> order_by([run], asc: run.started_at)
    |> preload([:worker, job: [:issue, :repository]])
    |> Repo.all()
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

  defp dispatch_capacity_available(repo) do
    max = Application.get_env(:ptc_manager, :dispatch_concurrency, 1)

    active_count =
      Job
      |> where([job], job.state in ^@capacity_job_states)
      |> repo.aggregate(:count)

    if active_count < max, do: :ok, else: {:error, :dispatch_capacity}
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

  defp get_or_create_dispatch_worker!(worker_key, dispatch, now) do
    attrs = %{
      worker_key: worker_key,
      name: "Herdr #{dispatch.session}",
      status: "online",
      capabilities: %{"herdr" => true, "dispatch" => true},
      last_heartbeat_at: now
    }

    case Repo.get_by(Worker, worker_key: worker_key) do
      nil -> %Worker{} |> Worker.changeset(attrs) |> Repo.insert!()
      worker -> worker |> Worker.changeset(attrs) |> Repo.update!()
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

  defp notify_and_return(result) do
    notify_changed(__MODULE__)
    result
  end

  defp issue_is_open(%Issue{state: "open"}), do: :ok
  defp issue_is_open(%Issue{}), do: {:error, :issue_closed}

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
