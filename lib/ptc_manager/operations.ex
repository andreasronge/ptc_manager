defmodule PtcManager.Operations do
  @moduledoc """
  Owns PtcManager's durable issue approvals, jobs, workers, and agent activity.

  GitHub reconciliation and execution adapters will enter through this boundary
  in later slices. Model output is stored as an immutable proposal and never
  performs an external effect directly.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias PtcManager.Gateway
  alias PtcManager.Repo
  alias PtcManager.RepoTransaction
  alias PtcManager.RuntimeIncarnation
  alias PtcManager.Repository.Checkout
  alias PtcManager.WorktreeSecurity
  alias PtcManager.Operations.DependencyGraph

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
    StopReport,
    Worker,
    WorktreeAllocation
  }

  @active_job_states ~w(queued starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open publish_blocked)
  @capacity_job_states ~w(starting working idle blocked reconciling)
  @capacity_run_states ~w(queued starting working idle unknown)
  @cancellable_job_states ~w(starting working idle blocked)
  # Deliberately excludes `reconciling`: that state can mean an agent whose
  # remote state is unknown rather than an agent-free phase, so ending the job
  # would free its slot while the agent may still be writing to the worktree.
  # Cancel agent, which closes the Herdr pane, is the right tool there.
  @abandonable_job_states ~w(awaiting_reconciliation verifying_result publish_blocked)
  @live_agent_run_states ~w(queued starting working idle blocked waiting unknown)
  @repair_action_keys ~w(repair_pr repair_and_merge_pr)
  @legacy_heavy_action_keys ["review_issue" | @repair_action_keys]
  @merge_action_key "repair_and_merge_pr"
  @planning_action_keys ~w(
    daily_digest
    prepare_issue
    report_issue_blocker
    post_cancellation_note
    review_issue
    resolve_issue_decision
  )
  @superseded_herdr_status "Superseded duplicate of the action-owned Herdr run."
  @topic "operations"
  @github_component ~r/\A[A-Za-z0-9_.-]+\z/

  def subscribe, do: Phoenix.PubSub.subscribe(PtcManager.PubSub, @topic)

  def notify_changed(source) do
    Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:operations_changed, source})
  end

  def list_repositories,
    do: Repository |> order_by([repository], asc: repository.id) |> Repo.all()

  def list_workers,
    do: Worker |> order_by([worker], asc: worker.id) |> Repo.all()

  def get_repository!(id), do: Repo.get!(Repository, id)
  def get_repository(id), do: Repo.get(Repository, id)

  def get_issue!(id), do: Issue |> preload(:repository) |> Repo.get!(id)

  @doc "The issue and its repository, or nil when the id no longer resolves."
  def get_issue(id), do: Issue |> preload(:repository) |> Repo.get(id)

  def create_repository(attrs) do
    insert_repository(attrs)
  end

  def onboard_repository(attrs) do
    with {:ok, attrs} <- prepare_repository(attrs),
         :ok <- verify_repository(attrs) do
      # Synchronization covers enabled repositories only, and a repository is
      # added disabled, so the label snapshet Configuration checks against has
      # to be taken here or it would stay empty until after enabling.
      attrs |> Map.merge(onboarding_labels(attrs)) |> insert_repository()
    end
  end

  @doc """
  Turns one repository's participation on or off, recording who decided.

  A repository is registered disabled so a maintainer can verify its checkout,
  contract, and access before any agent work or synchronization reaches it.
  Enabling is that decision, and disabling is how it is withdrawn: neither
  touches GitHub, the checkout, or work already in flight.
  """
  def set_repository_enabled(repository_id, enabled, actor)
      when is_integer(repository_id) and is_boolean(enabled) and is_binary(actor) and actor != "" do
    case Repo.get(Repository, repository_id) do
      nil ->
        {:error, :repository_not_found}

      repository ->
        outcome =
          RepoTransaction.immediate(fn ->
            updated =
              repository
              |> Repository.changeset(%{enabled: enabled})
              |> Repo.update!()

            insert_audit!(%{
              actor: actor,
              action: if(enabled, do: "repository.enabled", else: "repository.disabled"),
              target_type: "repository",
              target_id: repository.id,
              details: %{
                "repository" => "#{repository.github_owner}/#{repository.github_name}"
              }
            })

            updated
          end)

        case outcome do
          {:ok, updated} -> notify_and_return({:ok, updated})
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def with_repository_lifecycle_lock(repository_id, fun)
      when is_integer(repository_id) and is_function(fun, 0) do
    :global.trans({{PtcManager.RepositoryLifecycle, repository_id}, self()}, fun)
  end

  def remove_repository(repository_id) when is_integer(repository_id) do
    with_repository_lifecycle_lock(repository_id, fn ->
      do_remove_repository(repository_id)
    end)
  end

  defp do_remove_repository(repository_id) do
    result =
      RepoTransaction.immediate(fn ->
        repository = Repo.get(Repository, repository_id) || Repo.rollback(:repository_not_found)

        if repository_active_work?(repository_id), do: Repo.rollback(:active_work)

        delete_repository_records(repository_id)
        Repo.delete!(repository)
      end)

    case result do
      {:ok, repository} -> notify_and_return({:ok, repository})
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_repository(attrs) do
    Multi.new()
    |> Multi.insert(:repository, Repository.changeset(%Repository{}, attrs))
    |> Multi.run(:automations, fn _repo, %{repository: repository} ->
      case PtcManager.Automations.ensure_defaults(repository) do
        :ok -> {:ok, :seeded}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{repository: repository}} -> notify_and_return({:ok, repository})
      {:error, :repository, changeset, _changes} -> {:error, changeset}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp prepare_repository(attrs) do
    owner = onboarding_value(attrs, :github_owner)
    name = onboarding_value(attrs, :github_name)
    default_branch = onboarding_value(attrs, :default_branch)

    if safe_github_component?(owner) and safe_github_component?(name) do
      {:ok,
       %{
         github_owner: owner,
         github_name: name,
         default_branch: default_branch,
         local_path: "/srv/#{name}",
         enabled: false
       }}
    else
      {:error, :unsafe_repository_name}
    end
  end

  # A maintainer pastes these fields, and a paste routinely carries a leading or
  # trailing space or newline. That is not a name to reject; it is one to trim.
  defp onboarding_value(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      value when is_binary(value) -> String.trim(value)
      value -> value
    end
  end

  defp safe_github_component?(value),
    do:
      is_binary(value) and value not in [".", ".."] and byte_size(value) <= 100 and
        Regex.match?(@github_component, value)

  defp verify_repository(attrs) do
    client = Application.fetch_env!(:ptc_manager, :github_client)

    result =
      if Code.ensure_loaded?(client) and function_exported?(client, :get_repository, 2),
        do: client.get_repository(attrs.github_owner, attrs.github_name),
        else: {:error, :repository_lookup_unsupported}

    case result do
      {:ok, _repository} -> :ok
      {:error, :repository_not_found} -> {:error, :repository_not_found}
      {:error, _reason} -> {:error, :github_unavailable}
    end
  end

  defp onboarding_labels(attrs) do
    client = Application.fetch_env!(:ptc_manager, :github_client)
    repository = %Repository{github_owner: attrs.github_owner, github_name: attrs.github_name}

    case read_repository_labels(client, repository) do
      nil -> %{}
      names -> %{github_label_names: %{"names" => names}, github_labels_checked_at: utc_now()}
    end
  end

  @doc """
  The label names GitHub reports for one repository, or nil when unavailable.

  A failure is never fatal: the caller records nothing and Configuration keeps
  saying the labels have not been checked.
  """
  def read_repository_labels(client, %Repository{} = repository) do
    {module, arity} = if is_atom(client), do: {client, 1}, else: {client.__struct__, 2}

    if Code.ensure_loaded?(module) and function_exported?(module, :list_labels, arity) do
      case Gateway.call(client, :list_labels, [repository]) do
        {:ok, names} when is_list(names) -> names
        _unavailable -> nil
      end
    end
  end

  defp repository_active_work?(repository_id) do
    Repo.exists?(
      from job in Job,
        where: job.repository_id == ^repository_id and job.state in ^@active_job_states
    ) or
      Repo.exists?(
        from action in AgentAction,
          where:
            action.repository_id == ^repository_id and
              action.state in ["queued", "running", "sync_pending"]
      ) or
      Repo.exists?(
        from run in AgentRun,
          left_join: action in AgentAction,
          on: action.id == run.agent_action_id,
          left_join: job in Job,
          on: job.id == run.job_id,
          where:
            (action.repository_id == ^repository_id or job.repository_id == ^repository_id) and
              (run.state not in ["done", "failed", "lost"] or
                 (action.action_key in ^@repair_action_keys and not is_nil(run.herdr_workspace)) or
                 not is_nil(run.disposable_cleanup_state))
      ) or
      Repo.exists?(
        from invocation in PtcManager.Automations.Invocation,
          where:
            invocation.repository_id == ^repository_id and
              invocation.state in ["queued", "running", "synchronizing"]
      ) or
      Repo.exists?(
        from deployment in PtcManager.Deployments.Deployment,
          where:
            deployment.repository_id == ^repository_id and
              deployment.state in ["queued", "draining", "starting", "running"]
      ) or
      Repo.exists?(
        from publication in PrPublication,
          where:
            publication.repository_id == ^repository_id and
              publication.state in ["queued", "publishing"]
      ) or
      Repo.exists?(
        from operation in PtcManager.Operations.ResourceOperation,
          where:
            operation.repository_id == ^repository_id and
              operation.state not in ["completed", "failed", "cancelled", "lost"]
      ) or
      Repo.exists?(
        from allocation in WorktreeAllocation,
          join: job in Job,
          on: job.id == allocation.job_id,
          where:
            job.repository_id == ^repository_id and
              allocation.state != "removed"
      )
  end

  defp delete_repository_records(repository_id) do
    job_ids = from(job in Job, where: job.repository_id == ^repository_id, select: job.id)

    issue_ids =
      from(issue in Issue, where: issue.repository_id == ^repository_id, select: issue.id)

    action_ids =
      from(action in AgentAction,
        where: action.repository_id == ^repository_id,
        select: action.id
      )

    publication_ids =
      from(publication in PrPublication,
        where: publication.repository_id == ^repository_id,
        select: publication.id
      )

    proposal_ids =
      from(proposal in Proposal,
        where: proposal.issue_id in subquery(issue_ids),
        select: proposal.id
      )

    # A direct approval has no proposal, so the job it started is the only way
    # back to this repository. Read the ids before the jobs are deleted.
    approval_ids =
      Repo.all(
        from job in Job, where: job.repository_id == ^repository_id, select: job.approval_id
      )

    Repo.delete_all(
      from operation in PtcManager.Operations.ResourceOperation,
        where: operation.repository_id == ^repository_id
    )

    Repo.delete_all(
      from invocation in PtcManager.Automations.Invocation,
        where: invocation.repository_id == ^repository_id
    )

    Repo.delete_all(
      from digest in PtcManager.DailyDigests.DailyDigest,
        where: digest.repository_id == ^repository_id
    )

    Repo.delete_all(
      from approval in MergeApproval, where: approval.publication_id in subquery(publication_ids)
    )

    Repo.delete_all(
      from analysis in PrAnalysis, where: analysis.publication_id in subquery(publication_ids)
    )

    Repo.delete_all(
      from run in AgentRun,
        where: run.job_id in subquery(job_ids) or run.agent_action_id in subquery(action_ids)
    )

    Repo.delete_all(
      from allocation in WorktreeAllocation, where: allocation.job_id in subquery(job_ids)
    )

    Repo.delete_all(
      from publication in PrPublication, where: publication.repository_id == ^repository_id
    )

    Repo.delete_all(from job in Job, where: job.repository_id == ^repository_id)
    Repo.delete_all(from action in AgentAction, where: action.repository_id == ^repository_id)

    Repo.delete_all(
      from approval in Approval,
        where: approval.proposal_id in subquery(proposal_ids) or approval.id in ^approval_ids
    )

    Repo.delete_all(from proposal in Proposal, where: proposal.issue_id in subquery(issue_ids))
    Repo.delete_all(from issue in Issue, where: issue.repository_id == ^repository_id)

    Repo.delete_all(
      from deployment in PtcManager.Deployments.Deployment,
        where: deployment.repository_id == ^repository_id
    )

    definitions =
      from definition in PtcManager.Automations.Definition,
        where: definition.repository_id == ^repository_id

    Repo.update_all(definitions, set: [current_version_id: nil])
    Repo.delete_all(definitions)
  end

  @doc """
  Replaces one repository's configured maintainer labels.

  The list is configuration, not GitHub state: adding a name here never creates
  the label on GitHub, and the README says the label has to exist there first.
  """
  def update_maintainer_labels(repository_id, labels, actor)
      when is_integer(repository_id) and is_map(labels) and is_binary(actor) do
    case Repo.get(Repository, repository_id) do
      nil ->
        {:error, :repository_not_found}

      repository ->
        repository
        |> Repository.changeset(%{maintainer_labels: labels})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            insert_audit!(%{
              actor: actor,
              action: "repository.maintainer_labels_updated",
              target_type: "repository",
              target_id: repository_id,
              details: %{"labels" => labels}
            })

            notify_and_return({:ok, updated})

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc "Records that a maintainer added or removed one label on GitHub."
  def record_issue_label_change(%Issue{} = issue, operation, name, actor)
      when operation in [:add, :remove] and is_binary(name) and is_binary(actor) do
    insert_audit!(%{
      actor: actor,
      action: if(operation == :add, do: "issue.label_added", else: "issue.label_removed"),
      target_type: "issue",
      target_id: issue.id,
      details: %{
        "issue_number" => issue.number,
        "repository_id" => issue.repository_id,
        "label" => name
      }
    })

    notify_changed(__MODULE__)
    :ok
  end

  def create_issue(attrs),
    do: %Issue{} |> Issue.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_proposal(attrs),
    do: %Proposal{} |> Proposal.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_worker(attrs),
    do: %Worker{} |> Worker.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_agent_run(attrs),
    do: %AgentRun{} |> AgentRun.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def update_agent_run(%AgentRun{} = run, attrs),
    do: run |> AgentRun.changeset(attrs) |> Repo.update() |> broadcast_change()

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
          "automation_definition_version_id" => action.automation_definition_version_id,
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

  def claim_next_agent_action_for_lane(
        lane,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      when lane in [:planning, :writing] do
    case next_agent_action_candidate_for_lane(lane, now) do
      nil -> {:ok, nil}
      candidate -> do_claim_agent_action(candidate, now)
    end
  end

  def next_agent_action_candidate(now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)) do
    next_agent_action_candidate_for_lane(:any, now)
  end

  def next_agent_action_candidate_for_lane(
        lane,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond),
        resource_class \\ :any
      )
      when lane in [:any, :planning, :writing] and resource_class in [:any, "light", "heavy"] do
    blocked_repository_ids =
      AgentAction
      |> where([action], action.state == "sync_pending")
      |> agent_action_lane(lane)
      |> select([action], action.repository_id)
      |> distinct(true)
      |> Repo.all()

    base =
      AgentAction
      |> where(
        [action],
        action.state == "queued" and action.repository_id not in ^blocked_repository_ids and
          (is_nil(action.next_sync_attempt_at) or action.next_sync_attempt_at <= ^now)
      )
      |> agent_action_resource_class(resource_class)
      |> agent_action_lane(lane)

    if lane == :planning do
      base
      |> order_by([action], asc: action.requested_at, asc: action.id)
      |> limit(1)
      |> preload([:repository, :automation_definition_version])
      |> Repo.one()
    else
      next_writing_action(base)
    end
  end

  def planning_agent_action?(%AgentAction{automation_definition_version: %{queue_lane: lane}}),
    do: lane == "planning"

  def planning_agent_action?(%AgentAction{action_key: action_key}),
    do: planning_agent_action?(action_key)

  def planning_agent_action?(action_key) when is_binary(action_key),
    do: action_key in @planning_action_keys

  def planning_agent_action?(_action), do: false

  defp next_writing_action(base) do
    merge_candidate =
      base
      |> where(
        [action],
        action.action_key == @merge_action_key and
          action.repository_id not in subquery(active_writing_repository_ids())
      )
      |> order_by([action], asc: action.requested_at, asc: action.id)
      |> limit(1)
      |> preload([:repository, :automation_definition_version])
      |> Repo.one()

    merge_candidate ||
      base
      |> where(
        [action],
        action.repository_id not in subquery(active_merge_repository_ids())
      )
      |> order_by(
        [action],
        asc: fragment("CASE WHEN ? = 'repair_pr' THEN 0 ELSE 1 END", action.action_key),
        asc: action.requested_at,
        asc: action.id
      )
      |> limit(1)
      |> preload(:repository)
      |> Repo.one()
  end

  def list_queued_agent_actions do
    AgentAction
    |> where([action], action.state == "queued")
    |> order_by(
      [action],
      asc:
        fragment(
          "CASE WHEN ? = 'repair_and_merge_pr' THEN 0 WHEN ? = 'repair_pr' THEN 1 ELSE 2 END",
          action.action_key,
          action.action_key
        ),
      asc: action.requested_at,
      asc: action.id
    )
    |> preload([:repository, :automation_definition_version])
    |> Repo.all()
  end

  def list_queued_jobs do
    Job
    |> where([job], job.state == "queued")
    |> order_by([job], asc: job.inserted_at, asc: job.id)
    |> preload([:issue, :repository])
    |> Repo.all()
  end

  def cancel_queued_job(job_id, actor)
      when is_integer(job_id) and is_binary(actor) and actor != "" do
    cancel_queued(Job, job_id, actor, "job.cancelled")
  end

  def cancel_queued_agent_action(action_id, actor)
      when is_integer(action_id) and is_binary(actor) and actor != "" do
    cancel_queued(AgentAction, action_id, actor, "agent_action.cancelled")
  end

  @doc """
  Ends one running implementation agent on the maintainer's explicit request.

  Only the agent phases are cancellable. The deterministic phases that follow an
  agent — reconciliation, verification, and publication — are refused, because
  PtcManager, not an agent, owns them. The bookkeeping mirrors releasing an idle
  job: the job ends, its run ends, and the partial worktree is kept for
  attention rather than discarded. Closing the Herdr pane happens after the
  transaction commits, so a pane that outlives the cancel cannot resurrect the
  run.
  """
  def cancel_running_job(job_id, actor)
      when is_integer(job_id) and is_binary(actor) and actor != "" do
    now = utc_now()
    message = "Cancelled by #{actor}; the partial worktree was preserved."

    outcome =
      Repo.transaction(fn ->
        {updated, _rows} =
          Job
          |> where(
            [job],
            job.id == ^job_id and job.state in ^@cancellable_job_states and
              is_nil(job.review_recovery_expires_at)
          )
          |> Repo.update_all(
            set: [
              state: "cancelled",
              lease_expires_at: nil,
              ended_at: now,
              last_error: message,
              updated_at: now
            ]
          )

        if updated != 1, do: Repo.rollback(:job_not_cancellable)

        job = Repo.get!(Job, job_id)
        managed_review? = is_map(job.execution_settings)

        job =
          if managed_review? do
            saved =
              job
              |> Job.changeset(%{
                review_state: "cancelled",
                review_generation: job.review_generation + 1,
                cancellation_reason: message
              })
              |> Repo.update!()

            %{job_id: saved.id, generation: saved.review_generation}
            |> PtcManager.Reviews.CancelWorker.new()
            |> Oban.insert!()

            saved
          else
            job
          end

        run = current_job_run(job)

        if run && not managed_review? do
          end_cancelled_run(run, now)
        end

        mark_allocation!(job_id, %{
          state: "attention",
          last_used_at: now,
          last_error: message
        })

        insert_audit!(%{
          actor: actor,
          action: "job.cancelled",
          target_type: "job",
          target_id: job_id,
          details: %{
            "fencing_token" => job.fencing_token,
            "worktree_preserved" => true,
            "reason" => message,
            "agent_run_id" => run && run.id,
            "herdr_pane" => run && run.herdr_pane
          }
        })

        {job, run}
      end)

    case outcome do
      {:ok, {job, run}} ->
        result = close_cancelled_pane(job, run)

        if match?({:ok, _}, result) and is_nil(job.review_resume_expires_at) and
             is_map(job.execution_settings) and not is_nil(run) do
          end_cancelled_run(run, now)
        end

        notify_changed(__MODULE__)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_job_run(%Job{id: job_id, fencing_token: fencing_token}) do
    AgentRun
    |> where(
      [run],
      run.job_id == ^job_id and run.fencing_token == ^fencing_token and
        run.state in ^@live_agent_run_states
    )
    |> Repo.one()
  end

  defp end_cancelled_run(run, now) do
    Repo.get!(AgentRun, run.id)
    |> AgentRun.changeset(%{
      state: "lost",
      status_text: "Cancelled by maintainer",
      last_heartbeat_at: now,
      ended_at: now
    })
    |> Repo.update!()
  end

  defp close_cancelled_pane(job, %AgentRun{herdr_pane: pane})
       when is_binary(pane) and pane != "" do
    case Gateway.call(Application.fetch_env!(:ptc_manager, :herdr_client), :close_pane, [pane]) do
      :ok -> {:ok, job}
      {:error, reason} -> {:ok, job, {:pane_close_failed, reason}}
    end
  end

  defp close_cancelled_pane(job, _run), do: {:ok, job}

  @doc """
  Issues this attempt's stop-report identifier and returns the reloaded job.

  The token keeps two attempts from colliding and makes the file name
  impractical to guess. It is not a capability: every managed agent runs as the
  same worker identity and can list the shared results directory. See
  `PtcManager.Operations.StopReport` for what a forged report is bounded to.
  """
  def issue_stop_report_token(%Job{} = job) do
    job
    |> Job.changeset(%{stop_report_token: StopReport.new_token()})
    |> Repo.update()
  end

  @doc """
  Records that this job's agent said it could not finish, and ends the attempt.

  The report only supplies a reason. The transition is the same one every other
  unfinished attempt takes: the job ends, its run ends, and the partial worktree
  is kept for attention. The heavy slot is released, because a stopped agent
  waiting on a person must not hold capacity that other work needs.
  """
  def record_job_stop_report(job_id, fencing_token, attempt_token, report, actor \\ "coordinator")
      when is_integer(job_id) and is_integer(fencing_token) and is_binary(attempt_token) and
             is_map(report) and is_binary(actor) do
    now = utc_now()
    summary = StopReport.summary(report)

    outcome =
      Repo.transaction(fn ->
        # Same fencing as every other result write: only the verifier that
        # currently holds this attempt may end the job, and only from the state
        # it claimed. A stale verifier must never overwrite a newer success or a
        # job that already published.
        {updated, _rows} =
          Job
          |> where(
            [job],
            job.id == ^job_id and job.state == "verifying_result" and
              job.fencing_token == ^fencing_token and
              job.result_attempt_token == ^attempt_token
          )
          |> Repo.update_all(
            set: [
              state: "failed",
              lease_expires_at: nil,
              ended_at: now,
              last_error: summary,
              stop_report: report,
              stop_reported_at: now,
              stop_acknowledged_at: nil,
              updated_at: now
            ]
          )

        if updated != 1, do: Repo.rollback(:stale_result_attempt)

        job = Repo.get!(Job, job_id)

        AgentRun
        |> where(
          [run],
          run.job_id == ^job_id and run.fencing_token == ^job.fencing_token and
            run.state in ^@live_agent_run_states
        )
        |> Repo.update_all(
          set: [
            state: "lost",
            status_text: "The agent reported that it could not continue.",
            last_heartbeat_at: now,
            ended_at: now,
            updated_at: now
          ]
        )

        mark_allocation!(job_id, %{state: "attention", last_used_at: now, last_error: summary})

        insert_audit!(%{
          actor: actor,
          action: "job.agent_stopped",
          target_type: "job",
          target_id: job_id,
          details: Map.merge(report, %{"fencing_token" => job.fencing_token})
        })

        job
      end)

    case outcome do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Jobs whose agent stopped and which the maintainer has not answered yet."
  def unacknowledged_stopped_jobs do
    Job
    |> where([job], not is_nil(job.stop_reported_at) and is_nil(job.stop_acknowledged_at))
    |> order_by([job], desc: job.stop_reported_at, desc: job.id)
    |> preload([:issue, :repository])
    |> Repo.all()
  end

  @doc "Removes one stopped job's card from the board without changing GitHub."
  def acknowledge_job_stop(job_id, actor)
      when is_integer(job_id) and is_binary(actor) and actor != "" do
    now = utc_now()

    outcome =
      Repo.transaction(fn ->
        {updated, _rows} =
          Job
          |> where(
            [job],
            job.id == ^job_id and not is_nil(job.stop_reported_at) and
              is_nil(job.stop_acknowledged_at)
          )
          |> Repo.update_all(set: [stop_acknowledged_at: now, updated_at: now])

        if updated != 1, do: Repo.rollback(:job_not_stopped)

        insert_audit!(%{
          actor: actor,
          action: "job.stop_acknowledged",
          target_type: "job",
          target_id: job_id,
          details: %{"acknowledged_at" => DateTime.to_iso8601(now)}
        })

        Repo.get!(Job, job_id)
      end)

    case outcome do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Queues a fresh attempt at a stopped job, reusing the maintainer's approval.

  The decision to implement this issue was already made and has not changed;
  only the environment did. The new job repeats the frozen prompt and review
  count so the retry is the same work, not a new one.
  """
  def retry_stopped_job(job_id, actor)
      when is_integer(job_id) and is_binary(actor) and actor != "" do
    now = utc_now()

    outcome =
      RepoTransaction.immediate(fn ->
        stopped = Repo.get!(Job, job_id)

        if is_nil(stopped.stop_reported_at) or not is_nil(stopped.stop_acknowledged_at) do
          Repo.rollback(:job_not_stopped)
        end

        unless Repo.get!(Issue, stopped.issue_id).state == "open",
          do: Repo.rollback(:issue_not_open)

        if Repo.exists?(
             from j in Job, where: j.issue_id == ^stopped.issue_id and j.id > ^stopped.id
           ),
           do: Repo.rollback(:newer_job_exists)

        # A hidden button is not a guard. An agent that judged the work unsafe
        # must not be restartable through a crafted event either.
        unless StopReport.allows?(stopped.stop_report, :retry) do
          Repo.rollback(:recovery_not_offered)
        end

        {updated, _rows} =
          Job
          |> where([job], job.id == ^job_id and is_nil(job.stop_acknowledged_at))
          |> Repo.update_all(set: [stop_acknowledged_at: now, updated_at: now])

        if updated != 1, do: Repo.rollback(:job_not_stopped)

        retry =
          %Job{}
          |> Job.changeset(%{
            repository_id: stopped.repository_id,
            issue_id: stopped.issue_id,
            approval_id: stopped.approval_id,
            automation_definition_version_id: stopped.automation_definition_version_id,
            prompt_instructions: stopped.prompt_instructions,
            kind: stopped.kind,
            state: "queued",
            fencing_token: 0,
            required_review_count: stopped.required_review_count,
            execution_settings: stopped.execution_settings,
            review_state:
              if(stopped.execution_settings,
                do: if(stopped.required_review_count == 0, do: "skipped", else: "pending")
              )
          })
          |> Repo.insert!()

        insert_audit!(%{
          actor: actor,
          action: "job.retried_after_stop",
          target_type: "job",
          target_id: retry.id,
          details: %{
            "stopped_job_id" => stopped.id,
            "issue_id" => stopped.issue_id,
            "reason_code" => get_in(stopped.stop_report || %{}, ["reason_code"])
          }
        })

        retry
      end)

    case outcome do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ends a job stuck in a phase PtcManager owns and can never finish.

  An agent that committed nothing leaves its branch unverifiable, so the check
  fails identically every time and no button helps. Cancel deliberately refuses
  these phases because they are not agent phases; that leaves the maintainer
  with a card and no way out, which this closes.

  It refuses a phase that is still moving, and one that already produced a pull
  request, because abandoning either would discard real work. The bookkeeping
  matches cancelling: the job ends, the partial worktree is kept for attention,
  and the reason the phase was stuck is preserved beside the abandonment.
  """
  def abandon_stuck_job(job_id, actor)
      when is_integer(job_id) and is_binary(actor) and actor != "" do
    now = utc_now()

    outcome =
      Repo.transaction(fn ->
        job =
          Job
          |> where([item], item.id == ^job_id and item.state in ^@abandonable_job_states)
          |> Repo.one()

        if is_nil(job), do: Repo.rollback(:job_not_abandonable)

        # A verifier holding a live claim is still working; ending the job
        # underneath it would race its result write.
        if verification_claim_live?(job, now), do: Repo.rollback(:verification_in_progress)

        # A blocked publication can already have an open pull request. Ending
        # the job would orphan it: status reconciliation keeps selecting it and
        # then refuses it for a cancelled job, while the issue becomes free for
        # a second approval beside a pull request that still stands.
        if publication_open?(job_id), do: Repo.rollback(:pull_request_open)

        stuck_state = job.state
        stuck_error = job.last_error

        message =
          bounded_error(
            "Abandoned by #{actor} while #{stuck_state}" <>
              if(stuck_error, do: " (#{stuck_error})", else: "") <>
              "; the partial worktree was preserved."
          )

        # Guarded by the same state and claim the read saw, so a verifier claim
        # or a publication retry landing in between loses rather than colliding
        # with an unconditional write.
        {updated, _rows} =
          Job
          |> where([item], item.id == ^job_id and item.state == ^stuck_state)
          |> where(
            [item],
            is_nil(item.result_attempt_expires_at) or item.result_attempt_expires_at <= ^now
          )
          |> Repo.update_all(
            set: [
              state: "cancelled",
              lease_expires_at: nil,
              ended_at: now,
              last_error: message,
              updated_at: now
            ]
          )

        if updated != 1, do: Repo.rollback(:verification_in_progress)

        end_live_run!(job, message, now)

        mark_allocation!(job_id, %{state: "attention", last_used_at: now, last_error: message})

        insert_audit!(%{
          actor: actor,
          action: "job.abandoned",
          target_type: "job",
          target_id: job_id,
          details: %{
            "abandoned_state" => stuck_state,
            "last_error" => stuck_error,
            "fencing_token" => job.fencing_token,
            "worktree_preserved" => true
          }
        })

        Repo.get!(Job, job_id)
      end)

    case outcome do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, reason} -> {:error, reason}
    end
  end

  defp publication_open?(job_id) do
    Repo.exists?(
      from publication in PrPublication,
        where: publication.job_id == ^job_id and not is_nil(publication.pr_number)
    )
  end

  defp verification_claim_live?(%Job{result_attempt_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp verification_claim_live?(%Job{}, _now), do: false

  defp end_live_run!(%Job{} = job, message, now) do
    AgentRun
    |> where(
      [run],
      run.job_id == ^job.id and run.fencing_token == ^job.fencing_token and
        run.state in ^@live_agent_run_states
    )
    |> Repo.update_all(
      set: [
        state: "lost",
        status_text: String.slice(message, 0, 240),
        last_heartbeat_at: now,
        ended_at: now,
        updated_at: now
      ]
    )
  end

  def release_idle_job(job_id, actor)
      when is_integer(job_id) and is_binary(actor) and actor != "" do
    message = "The idle implementation attempt was released; its partial worktree was preserved."
    now = utc_now()

    case do_release_idle_job(job_id, nil, actor, message, now) do
      {:ok, job} -> notify_and_return({:ok, job})
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_queued(schema, id, actor, audit_action) do
    now = utc_now()

    outcome =
      Repo.transaction(fn ->
        {updated, _rows} =
          schema
          |> where([record], record.id == ^id and record.state == "queued")
          |> Repo.update_all(set: [state: "cancelled", ended_at: now, updated_at: now])

        if updated != 1, do: Repo.rollback(:work_no_longer_queued)

        insert_audit!(%{
          actor: actor,
          action: audit_action,
          target_type: if(schema == Job, do: "job", else: "agent_action"),
          target_id: id,
          details: %{"cancelled_at" => DateTime.to_iso8601(now)}
        })

        Repo.get!(schema, id)
      end)

    case outcome do
      {:ok, record} -> notify_and_return({:ok, record})
      {:error, reason} -> {:error, reason}
    end
  end

  def repository_merge_locked?(repository_id) when is_integer(repository_id) do
    AgentAction
    |> where(
      [action],
      action.repository_id == ^repository_id and action.action_key == @merge_action_key and
        action.state in ["queued", "running", "sync_pending"]
    )
    |> Repo.exists?()
  end

  def claim_agent_action(action_id, now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond))
      when is_integer(action_id) do
    action_id
    |> then(fn id ->
      AgentAction
      |> preload([:repository, :automation_definition_version])
      |> Repo.get(id)
    end)
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

  def record_agent_action_target_snapshot(action_id, snapshot, prompt \\ nil)
      when is_integer(action_id) and is_map(snapshot) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    updates =
      [
        target_snapshot: snapshot,
        sync_attempt_count: 0,
        next_sync_attempt_at: nil,
        last_error: nil,
        updated_at: now
      ]
      |> then(fn updates ->
        if is_binary(prompt), do: [{:prompt, prompt} | updates], else: updates
      end)

    {updated, _rows} =
      AgentAction
      |> where([action], action.id == ^action_id and action.state == "queued")
      |> Repo.update_all(set: updates)

    if updated == 1 do
      {:ok, AgentAction |> preload(:repository) |> Repo.get!(action_id)}
    else
      {:error, :agent_action_no_longer_queued}
    end
  end

  def mark_agent_action_source_released(action_id)
      when is_integer(action_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)

        snapshot =
          (action.target_snapshot || %{})
          |> Map.delete("source_path")
          |> Map.delete("source_cleanup_attempts")
          |> Map.delete("source_cleanup_error")
          |> Map.delete("source_cleanup_next_at")
          |> Map.put("source_released_at", DateTime.to_iso8601(now))

        action
        |> AgentAction.changeset(%{target_snapshot: snapshot})
        |> Repo.update!()
      end)

    case outcome do
      {:ok, action} ->
        notify_and_return({:ok, action})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def record_agent_action_source_cleanup_failure(action_id, reason)
      when is_integer(action_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        snapshot = action.target_snapshot || %{}
        attempts = max(snapshot["source_cleanup_attempts"] || 0, 0) + 1

        next_at =
          now
          |> DateTime.add(min(round(5 * :math.pow(2, min(attempts - 1, 10))), 3_600), :second)
          |> DateTime.to_iso8601()

        updated_snapshot =
          snapshot
          |> Map.put("source_cleanup_attempts", attempts)
          |> Map.put("source_cleanup_error", bounded_error(reason))
          |> Map.put("source_cleanup_next_at", next_at)

        action
        |> AgentAction.changeset(%{target_snapshot: updated_snapshot})
        |> Repo.update!()
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, action})
      {:error, failure} -> {:error, failure}
    end
  end

  def record_agent_action_repair_intent(action_id, attempt_token, repaired_sha)
      when is_integer(action_id) and is_binary(attempt_token) and is_binary(repaired_sha) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)

        if action.state != "running" or action.attempt_token != attempt_token,
          do: Repo.rollback(:agent_action_no_longer_running)

        snapshot =
          Map.put(action.target_snapshot || %{}, "repair_intended_head_sha", repaired_sha)

        action
        |> AgentAction.changeset(%{target_snapshot: snapshot, updated_at: now})
        |> Repo.update!()
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, Repo.preload(action, :repository)})
      {:error, reason} -> {:error, reason}
    end
  end

  def record_agent_action_decision_digest(action_id, content_digest)
      when is_integer(action_id) and is_binary(content_digest) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)

        if action.state not in ["running", "sync_pending"],
          do: Repo.rollback(:agent_action_not_recording_result)

        snapshot =
          Map.put(
            action.target_snapshot || %{},
            "decision_issue_content_digest",
            content_digest
          )

        action
        |> AgentAction.changeset(%{target_snapshot: snapshot, updated_at: now})
        |> Repo.update!()
      end)

    case outcome do
      {:ok, action} -> notify_and_return({:ok, Repo.preload(action, :repository)})
      {:error, reason} -> {:error, reason}
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
      {:ok, action} ->
        _ = PtcManager.Automations.reconcile_invocation(action)
        notify_and_return({:ok, action})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def defer_agent_action_preflight(action_id, reason, previous_attempt_count \\ 0)
      when is_integer(action_id) and is_integer(previous_attempt_count) and
             previous_attempt_count >= 0 do
    defer_agent_action_preflight(
      action_id,
      reason,
      previous_attempt_count,
      "Preflight GitHub synchronization pending",
      "sync_error"
    )
  end

  def defer_agent_action_source_preflight(action_id, reason, previous_attempt_count \\ 0)
      when is_integer(action_id) and is_integer(previous_attempt_count) and
             previous_attempt_count >= 0 do
    defer_agent_action_preflight(
      action_id,
      reason,
      previous_attempt_count,
      "Planning source snapshot pending",
      "source_error"
    )
  end

  defp defer_agent_action_preflight(
         action_id,
         reason,
         previous_attempt_count,
         error_prefix,
         audit_error_key
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        if action.state != "queued", do: Repo.rollback(:agent_action_no_longer_queued)

        sync_attempt_count = max(action.sync_attempt_count, previous_attempt_count) + 1

        deferred =
          action
          |> AgentAction.changeset(%{
            sync_attempt_count: sync_attempt_count,
            next_sync_attempt_at: next_sync_attempt_at(now, sync_attempt_count),
            last_error: "#{error_prefix}: #{bounded_error(reason)}"
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
            audit_error_key => bounded_error(reason)
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
    next_agent_action_sync_pending_for_lane(:any, now)
  end

  def next_agent_action_sync_pending_for_lane(
        lane,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      when lane in [:any, :planning, :writing] do
    AgentAction
    |> where(
      [action],
      action.state == "sync_pending" and
        (is_nil(action.next_sync_attempt_at) or action.next_sync_attempt_at <= ^now)
    )
    |> agent_action_lane(lane)
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

  def complete_agent_action_sync(action_id, {:ok, _summary}) when is_integer(action_id),
    do: complete_agent_action_sync_success(action_id, nil)

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
      {:ok, action} ->
        _ = PtcManager.Automations.reconcile_invocation(action)
        notify_and_return({:ok, action})

      {:error, reason} ->
        {:error, reason}
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

  def complete_agent_action_sync(action_id, {:ok, _summary}, {:ok, result})
      when is_integer(action_id) and is_map(result),
      do: complete_agent_action_sync_success(action_id, summarize_action_result(result))

  defp complete_agent_action_sync_success(action_id, recovered_result_summary) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        action = Repo.get!(AgentAction, action_id)
        if action.state != "sync_pending", do: Repo.rollback(:agent_action_not_sync_pending)

        result_summary = recovered_result_summary || action.result_summary
        final_state = if is_binary(result_summary), do: "done", else: "failed"

        completed =
          action
          |> AgentAction.changeset(%{
            state: final_state,
            ended_at: now,
            next_sync_attempt_at: nil,
            result_summary: result_summary,
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

  def next_queued_job do
    if heavy_delivery_action_active?() do
      nil
    else
      Job
      |> where([job], job.state == "queued")
      |> order_by([job], asc: job.inserted_at, asc: job.id)
      |> limit(1)
      |> preload([:approval, :issue, :repository])
      |> Repo.one()
    end
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
      job = Job |> preload([:issue, :repository, :worktree_allocation]) |> Repo.get!(job_id)
      notify_changed(__MODULE__)
      {:ok, job}
    else
      {:error, :result_already_claimed}
    end
  end

  def expire_job_leases(lease_now \\ utc_now(), lifecycle_now \\ utc_now()) do
    expired =
      Job
      |> where(
        [job],
        job.state in ["starting", "working", "idle", "blocked"] and
          not is_nil(job.lease_expires_at) and job.lease_expires_at <= ^lease_now
      )
      |> Repo.all()

    count = Enum.count(expired, &expire_job_lease(&1, lease_now, lifecycle_now))
    if count > 0, do: notify_changed(__MODULE__)
    count
  end

  def lease_job(job_id, worker_key, remote_issue, lease_ms, opts \\ [])
      when is_integer(job_id) and is_binary(worker_key) and is_map(remote_issue) and
             is_list(opts) do
    lease_now = Keyword.get_lazy(opts, :now, &utc_now/0)
    lifecycle_now = Keyword.get_lazy(opts, :lifecycle_now, &utc_now/0)
    capacity = Keyword.get(opts, :capacity, configured_agent_capacity())
    publication_source = configured_publication_source()

    result =
      Repo.transaction(fn ->
        job =
          Job
          |> preload([:approval, :issue, :repository, :automation_definition_version])
          |> Repo.get!(job_id)

        with :ok <- job_is_queued(job),
             :ok <- PtcManager.AutoImplementation.dispatch_allowed(job, remote_issue),
             {:ok, %{kind: agent_kind}} <- implementation_profile(job),
             :ok <- heavy_delivery_priority_unlocked(),
             :ok <- repository_dispatch_unlocked(job.repository_id),
             :ok <- issue_dependency_projection_matches(Repo, job.issue, remote_issue),
             :ok <- issue_dependencies_resolved(Repo, job.issue),
             {:ok, worker} <- ensure_capacity_worker(Repo, worker_key, capacity, lifecycle_now),
             :ok <- dispatch_capacity_available(Repo, worker, capacity, lifecycle_now),
             {:ok, worktree_path} <- worktree_path(job.repository, job.id, job.fencing_token + 1),
             :ok <- remote_issue_matches_approval(remote_issue, job.approval) do
          fencing_token = job.fencing_token + 1
          branch_name = "ptc-manager/issue-#{job.issue.number}-job-#{job.id}"
          lease_expires_at = DateTime.add(lease_now, lease_ms, :millisecond)

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
                started_at: lifecycle_now,
                branch_name: branch_name,
                publication_source: publication_source,
                last_error: nil,
                updated_at: lifecycle_now
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
              last_used_at: lifecycle_now
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

          {:error, :merge_priority} ->
            Repo.rollback(:merge_priority)

          {:error, :delivery_priority} ->
            Repo.rollback(:delivery_priority)

          {:error, reason} ->
            if WorktreeSecurity.infrastructure_error?(reason) do
              Repo.rollback(reason)
            else
              rejected = reject_job!(job, reason, lifecycle_now)
              {:rejected, reason, rejected}
            end
        end
      end)

    case result do
      {:ok, {:leased, job}} -> notify_and_return({:ok, job})
      {:ok, {:rejected, reason, _job}} -> notify_and_return({:error, reason})
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_job_working(
        job_id,
        fencing_token,
        worker_key,
        dispatch,
        lease_now \\ utc_now(),
        lifecycle_now \\ utc_now()
      ) do
    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, lease_now),
             {:ok, worker} <- current_dispatch_worker(Repo, worker_key) do
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
            last_used_at: lifecycle_now,
            last_error: nil
          })
          |> Repo.update!()

          run_attrs = %{
            worker_id: worker.id,
            job_id: job.id,
            role: Map.get(dispatch, :role, "implementer"),
            state: "working",
            agent_name: Map.get(dispatch, :agent_name),
            status_text: "Implementing the approved issue in an isolated worktree.",
            started_at: lifecycle_now,
            last_heartbeat_at: lifecycle_now,
            herdr_workspace: dispatch.workspace_id,
            herdr_pane: dispatch.pane_id,
            herdr_session: dispatch.session,
            external_key: dispatch.external_key,
            fencing_token: fencing_token,
            worker_incarnation_id: worker.worker_incarnation_id,
            herdr_incarnation_id: worker.herdr_incarnation_id,
            coordinator_incarnation_id: worker.coordinator_incarnation_id
          }

          run =
            case Repo.get_by(AgentRun, job_id: job.id, fencing_token: fencing_token) do
              nil ->
                %AgentRun{}
                |> AgentRun.changeset(run_attrs)
                |> Repo.insert!()

              existing ->
                existing
                |> AgentRun.changeset(run_attrs)
                |> Repo.update!()
            end

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

  def record_workspace_setup(
        job_id,
        fencing_token,
        worker_key,
        report,
        lease_now,
        lifecycle_now \\ utc_now()
      )
      when is_integer(job_id) and is_integer(fencing_token) and is_binary(worker_key) and
             is_map(report) do
    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, lease_now) do
          attrs =
            report
            |> workspace_setup_evidence()
            |> Map.merge(%{
              herdr_workspace: Map.get(report, :workspace_id),
              worktree_created_duration_ms: Map.get(report, :worktree_created_duration_ms),
              last_used_at: lifecycle_now,
              last_error: setup_error(report)
            })

          allocation =
            WorktreeAllocation
            |> Repo.get_by!(job_id: job.id)
            |> WorktreeAllocation.changeset(attrs)
            |> Repo.update!()

          insert_audit!(%{
            actor: "worker:#{worker_key}",
            action: "worktree.setup_#{report.state}",
            target_type: "worktree_allocation",
            target_id: allocation.id,
            details: %{
              "fencing_token" => fencing_token,
              "script" => report.script,
              "source_sha" => report.source_sha,
              "duration_ms" => report.duration_ms,
              "exit_status" => report.exit_status,
              "output_truncated" => report.output_truncated,
              "cache_state" => Map.get(report, :cache_state),
              "phase_durations" => Map.get(report, :phase_durations, %{}),
              "worktree_created_duration_ms" => report.worktree_created_duration_ms
            }
          })

          allocation
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, allocation} -> notify_and_return({:ok, allocation})
      {:error, reason} -> {:error, reason}
    end
  end

  def record_agent_action_workspace_setup(action_id, attempt_count, report)
      when is_integer(action_id) and is_integer(attempt_count) and is_map(report) do
    attrs =
      report
      |> workspace_setup_evidence()
      |> Map.put(:workspace_setup_error, setup_error(report))

    update_agent_action_attempt_run(action_id, attempt_count, attrs)
  end

  def prepare_agent_action_disposable_workspace(action_id, attempt_count, path, branch)
      when is_integer(action_id) and is_integer(attempt_count) and is_binary(path) and
             is_binary(branch) do
    update_agent_action_attempt_run(action_id, attempt_count, %{
      disposable_worktree_path: path,
      disposable_worktree_branch: branch,
      disposable_cleanup_state: "planned",
      disposable_cleanup_token: nil,
      disposable_cleanup_expires_at: nil,
      status_text: "Preparing a disposable investigation workspace."
    })
  end

  def attach_agent_action_disposable_workspace(
        action_id,
        attempt_count,
        workspace,
        pane,
        session
      )
      when is_integer(action_id) and is_integer(attempt_count) and is_binary(workspace) and
             is_binary(pane) and is_binary(session) do
    update_agent_action_attempt_run(action_id, attempt_count, %{
      herdr_workspace: workspace,
      herdr_pane: pane,
      herdr_session: session,
      disposable_cleanup_state: "workspace_open",
      status_text: "Bootstrapping a disposable investigation workspace."
    })
  end

  def claim_disposable_workspace_cleanup(
        run_id,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond)
      )
      when is_integer(run_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    lease_ms = Application.get_env(:ptc_manager, :disposable_cleanup_lease_ms, 300_000)
    expires_at = DateTime.add(now, lease_ms, :millisecond)

    {updated, _rows} =
      AgentRun
      |> where(
        [run],
        run.id == ^run_id and not is_nil(run.disposable_cleanup_state) and
          (is_nil(run.disposable_cleanup_token) or
             is_nil(run.disposable_cleanup_expires_at) or
             run.disposable_cleanup_expires_at <= ^now)
      )
      |> Repo.update_all(
        set: [
          disposable_cleanup_token: token,
          disposable_cleanup_expires_at: expires_at,
          updated_at: now
        ]
      )

    if updated == 1 do
      notify_changed(__MODULE__)
      {:ok, disposable_cleanup_run!(run_id), token}
    else
      {:error, :disposable_workspace_cleanup_already_claimed}
    end
  end

  def advance_disposable_workspace_cleanup(run_id, token, expected_state, next_state)
      when is_integer(run_id) and is_binary(token) and
             expected_state in ["planned", "workspace_open"] and next_state == "branch_pending" do
    disposable_cleanup_transition(run_id, token, expected_state, %{
      herdr_workspace: nil,
      herdr_pane: nil,
      external_key: nil,
      disposable_cleanup_state: next_state
    })
  end

  def fail_disposable_workspace_cleanup(run_id, token)
      when is_integer(run_id) and is_binary(token) do
    disposable_cleanup_transition(run_id, token, nil, %{
      disposable_cleanup_token: nil,
      disposable_cleanup_expires_at: nil
    })
  end

  def complete_disposable_workspace_cleanup(run_id, token)
      when is_integer(run_id) and is_binary(token) do
    disposable_cleanup_transition(run_id, token, "branch_pending", %{
      herdr_workspace: nil,
      herdr_pane: nil,
      external_key: nil,
      disposable_worktree_path: nil,
      disposable_worktree_branch: nil,
      disposable_cleanup_state: nil,
      disposable_cleanup_token: nil,
      disposable_cleanup_expires_at: nil
    })
  end

  defp disposable_cleanup_transition(run_id, token, expected_state, attrs) do
    now = utc_now()

    query =
      AgentRun
      |> where(
        [run],
        run.id == ^run_id and run.disposable_cleanup_token == ^token
      )
      |> maybe_expect_disposable_cleanup_state(expected_state)

    {updated, _rows} =
      Repo.update_all(query, set: Map.to_list(Map.put(attrs, :updated_at, now)))

    if updated == 1 do
      notify_changed(__MODULE__)
      {:ok, disposable_cleanup_run!(run_id)}
    else
      {:error, :stale_disposable_workspace_cleanup_claim}
    end
  end

  defp maybe_expect_disposable_cleanup_state(query, nil), do: query

  defp maybe_expect_disposable_cleanup_state(query, state),
    do: where(query, [run], run.disposable_cleanup_state == ^state)

  defp disposable_cleanup_run!(run_id) do
    AgentRun
    |> preload(agent_action: [:repository, :automation_definition_version])
    |> Repo.get!(run_id)
  end

  defp update_agent_action_attempt_run(action_id, attempt_count, attrs) do
    case AgentRun
         |> where(
           [run],
           run.agent_action_id == ^action_id and run.fencing_token == ^attempt_count and
             run.state in ["starting", "working", "unknown"]
         )
         |> order_by([run], desc: run.id)
         |> limit(1)
         |> Repo.one() do
      %AgentRun{} = run -> update_disposable_agent_run(run, attrs)
      nil -> {:error, :agent_action_run_missing}
    end
  end

  defp update_disposable_agent_run(%AgentRun{} = run, attrs) do
    run
    |> AgentRun.changeset(Map.put(attrs, :last_heartbeat_at, utc_now()))
    |> Repo.update()
    |> case do
      {:ok, updated} -> notify_and_return({:ok, updated})
      {:error, changeset} -> {:error, changeset}
    end
  end

  def attach_agent_action_herdr_run(action_id, attempt_count, dispatch)
      when is_integer(action_id) and is_integer(attempt_count) and is_map(dispatch) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        with {:ok, worker} <- current_dispatch_worker(Repo, dispatch.worker_key) do
          run =
            AgentRun
            |> where(
              [run],
              run.agent_action_id == ^action_id and run.fencing_token == ^attempt_count and
                run.state in ["starting", "working", "unknown"]
            )
            |> order_by([run], desc: run.id)
            |> limit(1)
            |> Repo.one!()

          with :ok <- action_run_matches_worker_incarnation(run, worker, dispatch) do
            run
            |> AgentRun.changeset(%{
              worker_id: worker.id,
              role: "implementer",
              state: "working",
              status_text:
                Map.get(dispatch, :status_text, "Repairing the existing pull request in Herdr."),
              last_heartbeat_at: now,
              agent_name: dispatch.agent_name,
              herdr_workspace: dispatch.workspace_id,
              herdr_pane: dispatch.pane_id,
              herdr_session: dispatch.session,
              external_key: dispatch.external_key
            })
            |> Repo.update!()
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case outcome do
      {:ok, run} -> notify_and_return({:ok, run})
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_dispatch_failed(
        job_id,
        fencing_token,
        worker_key,
        reason,
        lease_now \\ utc_now(),
        lifecycle_now \\ utc_now()
      ) do
    message = bounded_error(reason)

    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, lease_now) do
          failed =
            job
            |> Job.changeset(%{
              state: "failed",
              ended_at: lifecycle_now,
              lease_expires_at: nil,
              last_error: message,
              stop_report: %{
                "reason_code" => "environment_broken",
                "summary" => "PtcManager could not start the implementation.",
                "detail" => String.slice(message, 0, 2_000),
                "progress" => "none"
              },
              stop_reported_at: lifecycle_now,
              stop_acknowledged_at: nil
            })
            |> Repo.update!()

          mark_allocation!(job.id, %{
            state: "removed",
            removed_at: lifecycle_now,
            last_used_at: lifecycle_now
          })

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

  def mark_dispatch_uncertain(
        job_id,
        fencing_token,
        worker_key,
        reason,
        lease_now \\ utc_now(),
        lifecycle_now \\ utc_now()
      ) do
    message = bounded_error(reason)

    result =
      Repo.transaction(fn ->
        job = Repo.get!(Job, job_id)

        with :ok <- valid_lease(job, fencing_token, worker_key, lease_now) do
          reconciling =
            job
            |> Job.changeset(%{
              state: "reconciling",
              lease_expires_at: nil,
              reconciling_at: lease_now,
              absence_observed_at: nil,
              last_error: message
            })
            |> Repo.update!()

          mark_allocation!(job.id, %{
            state: "attention",
            last_used_at: lifecycle_now,
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

  def mark_result_verified(job_id, fencing_token, attempt_token, result, contract)
      when is_integer(job_id) and is_integer(fencing_token) and is_binary(attempt_token) and
             is_map(result) and
             (is_nil(contract) or is_struct(contract, PtcManager.Repository.Contract)) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    pre_publication_attrs = pre_publication_attrs(contract)

    outcome =
      if valid_result_fields?(result) do
        Repo.transaction(fn ->
          review_job = Repo.get!(Job, job_id)

          unless PtcManager.Reviews.publication_allowed?(review_job, result),
            do: Repo.rollback(:independent_review_required)

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
              set:
                [
                  state: "ready_for_pr",
                  result_base_sha: result.base_sha,
                  result_head_sha: result.head_sha,
                  result_diff_digest: result.diff_digest,
                  result_commit_count: result.commit_count,
                  result_verified_at: now,
                  result_attempt_expires_at: nil,
                  last_error: nil,
                  updated_at: now
                ] ++ pre_publication_attrs
            )

          if updated == 1 do
            job = Job |> Repo.get!(job_id) |> Repo.preload([:issue, :repository])

            mark_allocation!(job.id, %{
              state: "awaiting_pr",
              head_sha: result.head_sha,
              last_used_at: now,
              last_error: nil
            })

            publication_attrs = %{
              job_id: job.id,
              repository_id: job.repository_id,
              state: "queued",
              idempotency_key: publication_key(job, result),
              fencing_token: fencing_token,
              branch_name: job.branch_name,
              base_sha: result.base_sha,
              head_sha: result.head_sha,
              diff_digest: result.diff_digest,
              attempt_count: 0,
              next_attempt_at: nil,
              source: job.publication_source || "broker",
              title: job.issue.title,
              head_ref: job.branch_name,
              head_repository: "#{job.repository.github_owner}/#{job.repository.github_name}"
            }

            create_or_refresh_unpublished_publication!(job, publication_attrs)

            insert_audit!(%{
              actor: "coordinator",
              action: "job.result_verified",
              target_type: "job",
              target_id: job_id,
              details:
                Map.merge(
                  %{
                    "fencing_token" => fencing_token,
                    "base_sha" => result.base_sha,
                    "head_sha" => result.head_sha,
                    "diff_digest" => result.diff_digest,
                    "commit_count" => result.commit_count
                  },
                  pre_publication_audit_details(contract)
                )
            })

            job
          else
            job = Repo.get!(Job, job_id)

            if verified_result_matches?(job, fencing_token, attempt_token, result, contract),
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

  def dashboard_issues(opts \\ []) do
    state = Keyword.get(opts, :state)

    issues =
      Issue
      |> join(:inner, [issue], repository in assoc(issue, :repository))
      |> maybe_filter_issue_state(state)
      |> order_by([issue], desc: issue.github_updated_at)
      |> preload([_issue, repository], repository: repository)
      |> Repo.all()

    issue_ids = Enum.map(issues, & &1.id)
    proposals = latest_proposals(issue_ids)
    jobs = active_jobs(issue_ids)
    dependencies = dashboard_dependencies(issue_ids, jobs)
    dependency_cycles = dependency_cycles(issue_ids)
    latest_jobs = latest_jobs(issue_ids)
    publications = publications_for_jobs(Map.values(jobs) ++ Map.values(latest_jobs))
    publication_ids = publications |> Map.values() |> Enum.map(& &1.id)
    pr_analyses = latest_pr_analyses(publication_ids)
    merge_approvals = latest_merge_approvals(Map.values(pr_analyses))
    agent_actions = latest_agent_actions()
    retrospective_actions = latest_agent_actions("pr_retrospective")
    retrospective_issue_actions = retrospective_issue_actions()
    external_publications = external_publications_by_issue(issues)

    Enum.map(issues, fn issue ->
      %{
        issue: issue,
        external_publication: Map.get(external_publications, issue.id),
        dependencies: Map.get(dependencies, issue.id, []),
        dependency_cycle: Map.get(dependency_cycles, issue.id),
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
          end,
        pr_retrospective_action:
          case publication_for_issue(
                 publications,
                 Map.get(jobs, issue.id),
                 Map.get(latest_jobs, issue.id)
               ) do
            nil -> nil
            publication -> Map.get(retrospective_actions, {"pull_request", publication.id})
          end,
        pr_retrospective_issue_actions:
          case publication_for_issue(
                 publications,
                 Map.get(jobs, issue.id),
                 Map.get(latest_jobs, issue.id)
               ) do
            nil -> []
            publication -> Map.get(retrospective_issue_actions, publication.id, [])
          end
      }
    end)
  end

  # An issue whose pull request the maintainer opened by hand is being delivered
  # just as much as one PtcManager started. The link is the issue number that
  # publication already parsed out of the pull request body.
  defp external_publications_by_issue([]), do: %{}

  defp external_publications_by_issue(issues) do
    repository_ids = issues |> Enum.map(& &1.repository_id) |> Enum.uniq()

    linked =
      PrPublication
      |> where(
        [publication],
        publication.source == "external" and publication.state == "published" and
          publication.pr_state == "open" and publication.repository_id in ^repository_ids
      )
      |> Repo.all()
      |> Enum.flat_map(fn publication ->
        for number <- get_in(publication.linked_issue_numbers || %{}, ["numbers"]) || [],
            do: {{publication.repository_id, number}, publication}
      end)
      |> Map.new()

    issues
    |> Enum.flat_map(fn issue ->
      case Map.get(linked, {issue.repository_id, issue.number}) do
        nil -> []
        publication -> [{issue.id, publication}]
      end
    end)
    |> Map.new()
  end

  @doc """
  The pull requests Planning offers a retrospective for, with their context.

  A candidate is a managed pull request the implementation agent labelled
  `ptc:follow-up`, in any state, until a maintainer dismisses it or a
  retrospective finds nothing.
  """
  def follow_up_items do
    publications = PtcManager.Publications.follow_up_candidates()
    pr_actions = latest_agent_actions()
    retrospectives = latest_agent_actions("pr_retrospective")
    suggestions = retrospective_issue_actions()

    Enum.map(publications, fn publication ->
      %{
        publication: publication,
        repository: publication.job.repository,
        issue: publication.job.issue,
        pr_agent_action: Map.get(pr_actions, {"pull_request", publication.id}),
        pr_retrospective_action: Map.get(retrospectives, {"pull_request", publication.id}),
        pr_retrospective_issue_actions: Map.get(suggestions, publication.id, [])
      }
    end)
  end

  defp maybe_filter_issue_state(query, nil), do: query
  defp maybe_filter_issue_state(query, state), do: where(query, [issue], issue.state == ^state)

  def delivery_board_items do
    stopped_items = stopped_board_items()

    managed_items =
      dashboard_issues()
      |> Enum.reject(&is_nil(&1.active_job))
      |> Enum.map(fn item ->
        Map.merge(item, %{
          managed?: true,
          repository: item.issue.repository,
          title: (item.publication && item.publication.title) || item.issue.title,
          number: item.publication && item.publication.pr_number,
          url: item.publication && item.publication.pr_url,
          started_at: item.active_job.started_at || item.active_job.inserted_at,
          linked_issues: [item.issue]
        })
      end)

    external_publications =
      PrPublication
      |> where(
        [publication],
        publication.source == "external" and publication.state == "published" and
          publication.pr_state == "open"
      )
      |> order_by([publication], desc: publication.pr_checked_at, desc: publication.id)
      |> preload(:repository)
      |> Repo.all()

    publication_ids = Enum.map(external_publications, & &1.id)
    analyses = latest_pr_analyses(publication_ids)
    approvals = analyses |> Map.values() |> latest_merge_approvals()
    actions = latest_agent_actions()
    linked_issues = linked_issues_for_publications(external_publications)

    external_items =
      Enum.map(external_publications, fn publication ->
        %{
          managed?: false,
          repository: publication.repository,
          title: publication.title,
          number: publication.pr_number,
          url: publication.pr_url,
          started_at: publication.published_at || publication.inserted_at,
          issue: nil,
          dependencies: [],
          proposal: nil,
          active_job: nil,
          latest_job: nil,
          publication: publication,
          pr_analysis: Map.get(analyses, publication.id),
          merge_approval: Map.get(approvals, publication.id),
          issue_agent_action: nil,
          pr_agent_action: Map.get(actions, {"pull_request", publication.id}),
          pr_retrospective_action: nil,
          pr_retrospective_issue_actions: [],
          linked_issues: Map.get(linked_issues, publication.id, [])
        }
      end)

    managed_items ++ stopped_items ++ external_items
  end

  # A stopped job is no longer active, so it holds no capacity, but its card has
  # to stay until the maintainer decides what to do about it.
  defp stopped_board_items do
    Enum.map(unacknowledged_stopped_jobs(), fn job ->
      %{
        managed?: true,
        stopped?: true,
        repository: job.repository,
        title: job.issue.title,
        number: nil,
        url: nil,
        started_at: job.stop_reported_at,
        issue: job.issue,
        dependencies: [],
        dependency_cycle: nil,
        proposal: nil,
        active_job: job,
        latest_job: job,
        publication: nil,
        external_publication: nil,
        pr_analysis: nil,
        merge_approval: nil,
        issue_agent_action: nil,
        pr_agent_action: nil,
        pr_retrospective_action: nil,
        pr_retrospective_issue_actions: [],
        linked_issues: [job.issue]
      }
    end)
  end

  defp linked_issues_for_publications(publications) do
    references =
      for publication <- publications,
          number <- get_in(publication.linked_issue_numbers || %{}, ["numbers"]) || [],
          do: {publication.id, publication.repository_id, number}

    known_issues =
      references
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Enum.flat_map(fn {repository_id, numbers} ->
        numbers
        |> Enum.uniq()
        |> Enum.chunk_every(400)
        |> Enum.flat_map(fn chunk ->
          Issue
          |> where(
            [issue],
            issue.repository_id == ^repository_id and issue.number in ^chunk
          )
          |> Repo.all()
        end)
      end)
      |> Map.new(&{{&1.repository_id, &1.number}, &1})

    repositories = Map.new(publications, &{&1.repository_id, &1.repository})

    Enum.group_by(
      references,
      &elem(&1, 0),
      fn {_publication_id, repository_id, number} ->
        Map.get(known_issues, {repository_id, number}) ||
          external_issue_reference(repositories, repository_id, number)
      end
    )
  end

  defp external_issue_reference(repositories, repository_id, number) do
    repository = Map.fetch!(repositories, repository_id)

    %{
      number: number,
      title: nil,
      html_url:
        "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{number}"
    }
  end

  def list_agent_runs do
    AgentRun
    |> order_by([run], asc: run.started_at)
    |> preload([:worker, agent_action: :repository, job: [:issue, :repository]])
    |> Repo.all()
  end

  def list_active_agent_runs do
    AgentRun
    |> without_orphaned_action_duplicates()
    |> where([run], run.state in ~w(queued starting working idle blocked unknown))
    |> order_by([run], asc: run.started_at, asc: run.id)
    |> preload([
      :worker,
      agent_action: [:repository, :automation_definition_version],
      job: [:issue, :repository, :worktree_allocation]
    ])
    |> Repo.all()
  end

  @doc """
  Counts the light and heavy agent sessions occupying slots on online Herdr
  workers. Retained (waiting) sessions and runs on offline workers do not count.
  """
  def agent_slot_usage(now \\ DateTime.utc_now()) do
    agent_slot_usage(list_workers(), list_active_agent_runs(), now)
  end

  def agent_slot_usage(workers, active_runs, %DateTime{} = now) do
    online_worker_ids =
      workers
      |> Enum.filter(&herdr_worker_online?(&1, now))
      |> MapSet.new(& &1.id)

    {light, heavy} =
      Enum.reduce(active_runs, {0, 0}, fn run, {light, heavy} ->
        cond do
          run.state not in @capacity_run_states -> {light, heavy}
          not MapSet.member?(online_worker_ids, run.worker_id) -> {light, heavy}
          light_agent_run?(run) -> {light + 1, heavy}
          true -> {light, heavy + 1}
        end
      end)

    %{light: light, heavy: heavy, herdr_online?: MapSet.size(online_worker_ids) > 0}
  end

  def herdr_worker_online?(%Worker{} = worker, %DateTime{} = now) do
    stale_after_ms = Application.get_env(:ptc_manager, :herdr_stale_after_ms, 60_000)

    worker.status == "online" and worker.capabilities["herdr"] == true and
      match?(%DateTime{}, worker.last_heartbeat_at) and
      DateTime.diff(now, worker.last_heartbeat_at, :millisecond) < stale_after_ms
  end

  defp light_agent_run?(%AgentRun{agent_action: %AgentAction{} = action}),
    do: agent_action_resource_class(action) == "light"

  defp light_agent_run?(_run), do: false

  def agent_action_resource_class(%{
        automation_definition_version: %{resource_class: resource_class}
      })
      when resource_class in ["light", "heavy"],
      do: resource_class

  def agent_action_resource_class(%{action_key: action_key}) when is_binary(action_key) do
    if action_key in @legacy_heavy_action_keys, do: "heavy", else: "light"
  end

  def list_waiting_agent_runs do
    AgentRun
    |> without_orphaned_action_duplicates()
    |> where([run], run.state == "waiting")
    |> order_by([run], asc: run.last_heartbeat_at, asc: run.id)
    |> preload([
      :worker,
      agent_action: :repository,
      job: [:issue, :repository, :worktree_allocation]
    ])
    |> Repo.all()
  end

  def list_current_agent_runs do
    AgentRun
    |> without_orphaned_action_duplicates()
    |> where([run], run.state in ~w(queued starting working idle blocked waiting unknown))
    |> order_by([run], asc: run.started_at, asc: run.id)
    |> preload([
      :worker,
      agent_action: :repository,
      job: [:issue, :repository, :worktree_allocation]
    ])
    |> Repo.all()
  end

  def list_recent_agent_runs(limit \\ 5) when is_integer(limit) and limit > 0 do
    recent_agent_runs_query()
    |> limit(^limit)
    |> preload([
      :worker,
      agent_action: :repository,
      job: [:issue, :repository, :worktree_allocation]
    ])
    |> Repo.all()
  end

  def list_recent_agent_runs_for_repository(repository_id, limit \\ 5)
      when is_integer(repository_id) and is_integer(limit) and limit > 0 do
    recent_agent_runs_query()
    |> join(:left, [run], job in Job, on: job.id == run.job_id)
    |> join(:left, [run, job], action in AgentAction, on: action.id == run.agent_action_id)
    |> where(
      [run, job, action],
      job.repository_id == ^repository_id or action.repository_id == ^repository_id
    )
    |> limit(^limit)
    |> preload([
      :worker,
      agent_action: :repository,
      job: [:issue, :repository, :worktree_allocation]
    ])
    |> Repo.all()
  end

  defp recent_agent_runs_query do
    AgentRun
    |> without_orphaned_action_duplicates()
    |> where([run], run.state in ~w(done failed lost))
    |> where([run], is_nil(run.status_text) or run.status_text != ^@superseded_herdr_status)
    |> order_by([run], desc: run.ended_at, desc: run.id)
  end

  @doc """
  Lists the newest agent runs. Options narrow the list: `states` keeps only the
  given run states, and `include_maintenance: false` hides runs that belong to
  neither a job nor an agent action, such as deployment canaries.
  """
  def list_agent_timeline(limit \\ 40, opts \\ []) when is_integer(limit) and limit > 0 do
    AgentRun
    |> without_orphaned_action_duplicates()
    |> where([run], is_nil(run.status_text) or run.status_text != ^@superseded_herdr_status)
    |> filter_timeline_states(Keyword.get(opts, :states))
    |> filter_timeline_maintenance(Keyword.get(opts, :include_maintenance, true))
    |> order_by([run], desc: run.started_at, desc: run.id)
    |> limit(^limit)
    |> preload([
      :worker,
      agent_action: :repository,
      job: [:issue, :repository, :worktree_allocation]
    ])
    |> Repo.all()
  end

  defp without_orphaned_action_duplicates(query) do
    action_agent_names =
      from(linked in AgentRun,
        where: not is_nil(linked.agent_action_id) and not is_nil(linked.agent_name),
        select: linked.agent_name
      )

    where(
      query,
      [run],
      not is_nil(run.agent_action_id) or is_nil(run.agent_name) or
        run.agent_name not in subquery(action_agent_names)
    )
  end

  defp filter_timeline_states(query, nil), do: query
  defp filter_timeline_states(query, states), do: where(query, [run], run.state in ^states)

  defp filter_timeline_maintenance(query, true), do: query

  defp filter_timeline_maintenance(query, false),
    do: where(query, [run], not is_nil(run.job_id) or not is_nil(run.agent_action_id))

  def list_workers_with_worktrees do
    Worker
    |> order_by([worker], asc: worker.id)
    |> preload(worktree_allocations: [job: [:issue, :repository, :pr_publication, :agent_runs]])
    |> Repo.all()
  end

  def list_recent_workspace_setups(limit \\ 10) when is_integer(limit) and limit > 0 do
    WorktreeAllocation
    |> where([allocation], not is_nil(allocation.workspace_setup_state))
    |> order_by([allocation], desc: allocation.workspace_setup_ended_at, desc: allocation.id)
    |> limit(^limit)
    |> preload(job: [:issue, :repository])
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
    |> preload([allocation, worker],
      worker: worker,
      job: [:issue, :repository, :pr_publication, :agent_runs]
    )
    |> Repo.all()
  end

  def worktree_consumes_execution_slot?(%WorktreeAllocation{
        state: allocation_state,
        job: %Job{state: job_state} = job
      }) do
    not review_capacity_released?(job) and
      (allocation_state in ["reserved", "active"] or job_state in @capacity_job_states or
         execution_run_active?(job))
  end

  def worktree_consumes_execution_slot?(_allocation), do: false

  @doc "A retained review workspace is not a slot once its implementer is confirmed stopped."
  def review_capacity_released?(%Job{state: state, agent_runs: runs} = job)
      when state in ~w(blocked working idle) and is_list(runs) do
    waiting =
      job.review_state in ~w(paused manual) or
        (job.review_state == "resume_pending" and is_nil(job.review_resume_expires_at)) or
        (job.review_state == "running" and job.review_resume_mode == "assessment")

    waiting and
      Enum.any?(
        runs,
        &(&1.role == "implementer" and &1.fencing_token == job.fencing_token and
            &1.state in ~w(done failed lost))
      ) and
      Enum.all?(runs, &(&1.role != "implementer" or &1.state in ~w(done failed lost)))
  end

  def review_capacity_released?(_job), do: false

  defp released_review_job_ids(repo \\ Repo) do
    Job
    |> where([job], job.review_state in ~w(paused manual resume_pending running))
    |> preload(:agent_runs)
    |> repo.all()
    |> Enum.filter(&review_capacity_released?/1)
    |> Enum.map(& &1.id)
  end

  @doc "Atomically reserves shared worker capacity before resuming retained review work."
  def claim_review_continuation(id, generation) do
    RepoTransaction.immediate(fn ->
      job =
        Repo.get!(Job, id)
        |> Repo.preload([:repository, :issue, :agent_runs, worktree_allocation: :worker])

      unless job.review_state == "resume_pending" and job.review_generation == generation,
        do: Repo.rollback(:stale_continuation)

      unless is_nil(job.review_resume_expires_at),
        do: Repo.rollback(:continuation_already_claimed)

      unless is_nil(job.review_recovery_expires_at), do: Repo.rollback(:recovery_busy)

      unless job.worktree_allocation && job.worktree_allocation.state != "removed",
        do: Repo.rollback(:retained_workspace_not_ready)

      unless review_capacity_released?(job), do: Repo.rollback(:retained_agent_not_stopped)

      worker = job.worktree_allocation.worker
      now = utc_now()

      with :ok <- repository_dispatch_unlocked(job.repository_id),
           :ok <- heavy_delivery_priority_unlocked(),
           {:ok, capacity} <- worker_execution_capacity(worker),
           :ok <- dispatch_capacity_available(Repo, worker, capacity, now) do
        job
        |> Job.changeset(%{
          review_resume_expires_at: DateTime.add(now, 600, :second),
          last_error: nil
        })
        |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp execution_run_active?(%Job{agent_runs: runs}) when is_list(runs),
    do: Enum.any?(runs, &(&1.role == "implementer" and &1.state in @capacity_run_states))

  defp execution_run_active?(_job), do: false

  def dispatch_capacity(worker_key) when is_binary(worker_key) do
    case Repo.get_by(Worker, worker_key: worker_key) do
      %Worker{status: "online", capabilities: capabilities} = worker ->
        if worker_admitted?(worker) do
          case capabilities["implementation_slots"] do
            capacity when is_integer(capacity) and capacity > 0 -> {:ok, capacity}
            _capacity -> {:error, :worker_has_no_implementation_capacity}
          end
        else
          {:error, :worker_unavailable}
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
      from: ~w(reserved active awaiting_pr warm waiting reclaimable attention terminal)
    )
  end

  def reserve_worktree_for_repair(job_id, actor \\ "coordinator")
      when is_integer(job_id) and is_binary(actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    outcome =
      Repo.transaction(fn ->
        job = Repo.get(Job, job_id)

        allocation =
          WorktreeAllocation
          |> where([allocation], allocation.job_id == ^job_id)
          |> preload(:worker)
          |> Repo.one()

        with %Job{state: "pr_open"} <- job,
             %WorktreeAllocation{state: state, worker: worker} = allocation <- allocation,
             true <- state in ~w(warm waiting reclaimable attention),
             {:ok, capacity} <- worker_execution_capacity(worker),
             :ok <- dispatch_capacity_available(Repo, worker, capacity, now) do
          updated =
            allocation
            |> WorktreeAllocation.changeset(%{
              state: "active",
              last_used_at: now,
              last_error: nil
            })
            |> Repo.update!()

          insert_audit!(%{
            actor: actor,
            action: "worktree.active",
            target_type: "worktree_allocation",
            target_id: allocation.id,
            details: %{"job_id" => job_id, "reason" => nil}
          })

          updated
        else
          {:error, reason} -> Repo.rollback(reason)
          _invalid -> Repo.rollback(:repair_worktree_not_available)
        end
      end)

    broadcast_change(outcome)
  end

  def release_repair_worktree(job_id, head_sha, actor \\ "coordinator")
      when is_integer(job_id) and is_binary(head_sha) and is_binary(actor) do
    case Repo.get_by(WorktreeAllocation, job_id: job_id) do
      nil ->
        {:ok, nil}

      %{state: "active"} = allocation ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        outcome =
          allocation
          |> WorktreeAllocation.changeset(%{
            state: "waiting",
            head_sha: head_sha,
            last_used_at: now,
            last_error: nil
          })
          |> Repo.update()

        case outcome do
          {:ok, updated} ->
            insert_audit!(%{
              actor: actor,
              action: "worktree.repair_released",
              target_type: "worktree_allocation",
              target_id: allocation.id,
              details: %{"job_id" => job_id, "head_sha" => head_sha}
            })

            notify_and_return({:ok, updated})

          error ->
            error
        end

      _allocation ->
        {:error, :repair_worktree_not_reserved}
    end
  end

  @doc "Loads one allocation with everything the cleanup policy inspects."
  def get_worktree_allocation(allocation_id) when is_integer(allocation_id) do
    WorktreeAllocation
    |> preload(job: [:issue, :repository, :pr_publication, :agent_runs])
    |> Repo.get(allocation_id)
  end

  def claim_worktree_cleanup(
        allocation_id,
        now \\ DateTime.utc_now() |> DateTime.truncate(:microsecond),
        opts \\ []
      )
      when is_integer(allocation_id) and is_list(opts) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    expires_at = DateTime.add(now, 300, :second)
    claimable_states = Keyword.get(opts, :from, ["terminal", "reclaimable"])

    {updated, _rows} =
      WorktreeAllocation
      |> where(
        [allocation],
        allocation.id == ^allocation_id and
          (allocation.state in ^claimable_states or
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
        |> preload(job: [:issue, :repository, :pr_publication])
        |> Repo.get!(allocation_id)

      {:ok, claimed, token}
    else
      {:error, :worktree_cleanup_already_claimed}
    end
  end

  def complete_worktree_cleanup(allocation_id, token, audit \\ nil)
      when is_integer(allocation_id) and is_binary(token) do
    case cleanup_transition(allocation_id, token, "removed", nil) do
      {:ok, allocation} = removed ->
        record_worktree_removal(allocation, audit)
        removed

      error ->
        error
    end
  end

  defp record_worktree_removal(allocation, %{actor: actor, reason: reason})
       when is_binary(actor) and is_binary(reason) do
    insert_audit!(%{
      actor: actor,
      action: "worktree.removed",
      target_type: "worktree_allocation",
      target_id: allocation.id,
      details: %{"job_id" => allocation.job_id, "reason" => reason}
    })
  end

  defp record_worktree_removal(_allocation, _audit), do: :ok

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

  def approve_issue(issue_id, actor, requested_review_count \\ nil, profile \\ nil)
      when is_integer(issue_id) and is_binary(actor) do
    with :ok <- valid_requested_review_count(requested_review_count) do
      do_approve_issue(issue_id, actor, requested_review_count, :prepared, profile)
    end
  end

  @doc """
  Approves implementation for an issue that has no prepared proposal.

  Every deterministic gate of `approve_issue/3` still applies: the issue must be
  open, unclaimed, projected, free of a conflicting or blocking workflow label,
  and free of unresolved dependencies. Only the two proposal checks are skipped,
  because a small issue does not need a preparation round. The click is the
  approval.
  """
  def approve_issue_directly(issue_id, actor, requested_review_count \\ nil, profile \\ nil)
      when is_integer(issue_id) and is_binary(actor) do
    with :ok <- valid_requested_review_count(requested_review_count) do
      do_approve_issue(issue_id, actor, requested_review_count, :direct, profile)
    end
  end

  @doc "Queues one ready issue under the repository's explicit automatic implementation policy."
  def auto_approve_issue(issue_id) when is_integer(issue_id) do
    do_approve_issue(issue_id, "system:auto-fix", nil, :automatic, nil)
  end

  defp do_approve_issue(issue_id, actor, requested_review_count, mode, profile) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Multi.new()
    |> Multi.run(:snapshot, fn repo, _changes ->
      current_approvable_snapshot(repo, issue_id, mode)
    end)
    |> Multi.run(:execution, fn _repo, %{snapshot: {_issue, proposal, _repository}} ->
      case PtcManager.ExecutionProfiles.freeze(proposal, profile, requested_review_count) do
        {:ok, settings, budget} -> {:ok, %{settings: settings, budget: budget}}
        error -> error
      end
    end)
    |> Multi.run(:automation, fn _repo, %{snapshot: {_issue, _proposal, repository}} ->
      with :ok <- PtcManager.Automations.ensure_defaults(repository),
           {:ok, version} <- PtcManager.Automations.current_version(repository, "implement_issue") do
        {:ok,
         {version,
          PtcManager.Automations.resolved_instructions(
            version,
            nil
          )}}
      end
    end)
    |> Multi.insert(:approval, fn %{snapshot: {issue, proposal, _repository}} ->
      Approval.changeset(%Approval{}, %{
        proposal_id: proposal && proposal.id,
        decision: approval_decision(mode),
        actor: actor,
        source_updated_at: issue.github_updated_at,
        source_digest: issue.content_digest,
        proposal_digest: proposal && proposal.proposal_digest,
        approved_at: now
      })
    end)
    |> Multi.insert(:job, fn %{
                               snapshot: {issue, _proposal, _repository},
                               approval: approval,
                               automation: {version, prompt_instructions},
                               execution: execution
                             } ->
      Job.changeset(%Job{}, %{
        repository_id: issue.repository_id,
        issue_id: issue.id,
        approval_id: approval.id,
        automation_definition_version_id: version.id,
        prompt_instructions: prompt_instructions,
        kind: "implementation",
        state: "queued",
        fencing_token: 0,
        required_review_count: execution.budget,
        execution_settings:
          Map.merge(execution.settings, %{
            "issue_title" => issue.title,
            "issue_body" => String.slice(issue.body || "", 0, 20_000),
            "issue_comment_count_at_submission" => issue.github_comment_count,
            "issue_comments_observed_at_submission" =>
              if(issue.comments_checked_at, do: DateTime.to_iso8601(issue.comments_checked_at))
          }),
        review_state: if(execution.budget == 0, do: "skipped", else: "pending")
      })
    end)
    |> Multi.insert(:audit_event, fn %{
                                       snapshot: {issue, proposal, _repository},
                                       job: job
                                     } ->
      AuditEvent.changeset(%AuditEvent{}, %{
        actor: actor,
        action: audit_action(mode),
        target_type: "job",
        target_id: job.id,
        details: %{
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "proposal_id" => proposal && proposal.id,
          "required_review_count" => job.required_review_count,
          "execution_settings" => job.execution_settings,
          "proposal_digest" => proposal && proposal.proposal_digest,
          "source_digest" => issue.content_digest
        }
      })
    end)
    |> RepoTransaction.immediate()
    |> normalize_approval_result()
    |> tap(fn
      {:ok, job} -> PtcManager.Automations.link_job_invocation(job, actor)
      _result -> :ok
    end)
    |> broadcast_change()
  end

  defp approval_decision(:automatic), do: "start_implementation_automatic"
  defp approval_decision(:direct), do: "start_implementation_direct"
  defp approval_decision(_mode), do: "start_implementation"

  defp audit_action(:automatic), do: "issue.automatically_approved_for_implementation"
  defp audit_action(:direct), do: "issue.approved_for_direct_implementation"
  defp audit_action(_mode), do: "issue.approved_for_implementation"

  defp current_approvable_snapshot(repo, issue_id, mode) do
    with %Issue{} = issue <- repo.get(Issue, issue_id),
         :ok <- automatic_approval_allowed(repo, issue, mode),
         :ok <- issue_is_open(issue),
         :ok <- issue_unclaimed(issue),
         :ok <- issue_workflow_allows_implementation(issue),
         :ok <- issue_dependencies_resolved(repo, issue),
         :ok <- issue_not_collection(issue),
         {:ok, proposal} <- approvable_proposal(repo, issue, mode) do
      {:ok, {issue, proposal, repo.get!(Repository, issue.repository_id)}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp automatic_approval_allowed(repo, issue, :automatic),
    do: PtcManager.AutoImplementation.eligible(repo, issue)

  defp automatic_approval_allowed(_repo, _issue, _mode), do: :ok

  defp approvable_proposal(repo, issue, :automatic) do
    case latest_proposal(repo, issue.id) do
      nil ->
        {:ok, nil}

      proposal ->
        # A fresh analysis that asked for a breakdown is a reason not to start
        # unattended; a stale or absent one keeps today's standard fallback.
        cond do
          proposal_matches_issue(proposal, issue) != :ok -> {:ok, nil}
          proposal.readiness == "needs_breakdown" -> {:error, :issue_needs_breakdown}
          true -> {:ok, proposal}
        end
    end
  end

  defp approvable_proposal(_repo, _issue, :direct), do: {:ok, nil}

  defp approvable_proposal(repo, issue, _mode) do
    with %Proposal{} = proposal <- latest_proposal(repo, issue.id),
         :ok <- proposal_is_ready(proposal),
         :ok <- proposal_matches_issue(proposal, issue) do
      {:ok, proposal}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_requested_review_count(nil), do: :ok
  defp valid_requested_review_count(count) when count in 0..5, do: :ok
  defp valid_requested_review_count(_count), do: {:error, :invalid_review_count}

  defp job_is_queued(%Job{state: "queued"}), do: :ok
  defp job_is_queued(%Job{}), do: {:error, :already_leased}

  defp configured_publication_source do
    if Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false),
      do: "agent",
      else: "broker"
  end

  defp dispatch_capacity_available(_repo, _worker, capacity, _now)
       when not is_integer(capacity) or capacity < 1,
       do: {:error, :invalid_agent_capacity}

  defp dispatch_capacity_available(repo, worker, capacity, now) do
    # This harmless write obtains SQLite's writer lock before the count. Initial
    # dispatch and retained-PR repair therefore share one serialized slot gate.
    Worker
    |> where([candidate], candidate.id == ^worker.id)
    |> repo.update_all(set: [updated_at: now])

    released_reviews = released_review_job_ids(repo)

    active_allocation_count =
      WorktreeAllocation
      |> join(:inner, [allocation], job in Job,
        as: :capacity_job,
        on: job.id == allocation.job_id
      )
      |> where(
        [allocation, job],
        allocation.worker_id == ^worker.id and job.id not in ^released_reviews and
          (allocation.state in ["reserved", "active"] or
             job.state in ^@capacity_job_states or
             exists(
               from run in AgentRun,
                 where:
                   run.job_id == parent_as(:capacity_job).id and run.role == "implementer" and
                     run.state in ^@capacity_run_states
             ))
      )
      |> repo.aggregate(:count)

    legacy_job_count =
      Job
      |> from(as: :legacy_job)
      |> where(
        [job],
        job.lease_owner == ^worker.worker_key and job.state in ^@capacity_job_states and
          job.id not in ^released_reviews and
          not exists(
            from allocation in WorktreeAllocation,
              where: allocation.job_id == parent_as(:legacy_job).id
          )
      )
      |> repo.aggregate(:count)

    active_action_run_count =
      AgentRun
      |> join(:inner, [run], action in AgentAction, on: action.id == run.agent_action_id)
      |> join(:left, [run, action], publication in PrPublication,
        on: action.target_type == "pull_request" and publication.id == action.target_id
      )
      |> join(
        :left,
        [run, action, publication],
        version in assoc(action, :automation_definition_version)
      )
      |> where(
        [run, action, publication, version],
        run.worker_id == ^worker.id and not is_nil(run.agent_action_id) and
          run.state in ^@capacity_run_states and
          (version.resource_class == "heavy" or
             (is_nil(version.id) and action.action_key in ^@legacy_heavy_action_keys)) and
          (action.action_key not in ^@repair_action_keys or is_nil(publication.job_id))
      )
      |> repo.aggregate(:count)

    if active_allocation_count + legacy_job_count + active_action_run_count < capacity,
      do: :ok,
      else: {:error, :dispatch_capacity}
  end

  defp worker_execution_capacity(%Worker{status: "online", capabilities: capabilities} = worker) do
    if worker_admitted?(worker) do
      case capabilities["implementation_slots"] do
        capacity when is_integer(capacity) and capacity > 0 ->
          {:ok, capacity}

        _capacity ->
          if capabilities["herdr"],
            do: {:ok, configured_agent_capacity()},
            else: {:error, :worker_has_no_implementation_capacity}
      end
    else
      {:error, :worker_unavailable}
    end
  end

  defp worker_execution_capacity(%Worker{}), do: {:error, :worker_unavailable}

  defp ensure_capacity_worker(_repo, _worker_key, capacity, _now)
       when not is_integer(capacity) or capacity < 1,
       do: {:error, :invalid_agent_capacity}

  defp ensure_capacity_worker(repo, worker_key, capacity, _now) do
    case repo.get_by(Worker, worker_key: worker_key) do
      nil ->
        {:error, :worker_unavailable}

      %Worker{status: "online", capabilities: capabilities} = worker ->
        cond do
          not worker_admitted?(worker) -> {:error, :worker_unavailable}
          capabilities["implementation_slots"] == capacity -> {:ok, worker}
          true -> {:error, :worker_capacity_changed}
        end

      %Worker{} ->
        {:error, :worker_unavailable}
    end
  end

  defp worktree_path(repository, job_id, fencing_token) do
    root = Application.get_env(:ptc_manager, :worktree_root)

    with true <- is_binary(root) and Path.type(root) == :absolute,
         :ok <- WorktreeSecurity.validate_configured_root(root) do
      {:ok,
       Path.join(
         Path.expand(root),
         "#{Checkout.slug(repository)}-job-#{job_id}-f#{fencing_token}"
       )}
    else
      false -> {:error, :worktree_root_unavailable}
      {:error, reason} -> {:error, reason}
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
    message = rejection_error(reason)

    {updated, _rows} =
      Job
      |> where(
        [candidate],
        candidate.id == ^job.id and candidate.state == "queued" and
          candidate.fencing_token == ^job.fencing_token
      )
      |> Repo.update_all(
        set: [state: "cancelled", ended_at: now, last_error: message, updated_at: now]
      )

    if updated == 1 do
      insert_audit!(%{
        actor: "coordinator",
        action: "job.dispatch_rejected",
        target_type: "job",
        target_id: job.id,
        details: %{"reason" => message}
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
      DateTime.compare(job.lease_expires_at, now) != :gt -> {:error, :lease_expired}
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

  defp verified_result_matches?(job, fencing_token, attempt_token, result, contract) do
    job.state == "ready_for_pr" and job.fencing_token == fencing_token and
      job.result_attempt_token == attempt_token and job.result_base_sha == result.base_sha and
      job.result_head_sha == result.head_sha and
      job.result_diff_digest == result.diff_digest and
      job.result_commit_count == result.commit_count and pre_publication_matches?(job, contract)
  end

  defp pre_publication_attrs(nil) do
    [
      pre_publication_bootstrap_command: nil,
      pre_publication_bootstrap_timeout_ms: nil,
      pre_publication_command: nil,
      pre_publication_timeout_ms: nil,
      pre_publication_config_digest: nil,
      pre_publication_status: nil,
      pre_publication_verified_sha: nil,
      pre_publication_exit_status: nil,
      pre_publication_output: nil,
      pre_publication_duration_ms: nil,
      pre_publication_verified_at: nil
    ]
  end

  defp pre_publication_attrs(contract) do
    [
      pre_publication_bootstrap_command: contract.bootstrap_command,
      pre_publication_bootstrap_timeout_ms: contract.bootstrap_timeout_minutes * 60_000,
      pre_publication_command: contract.before_publish_command,
      pre_publication_timeout_ms: contract.verification_timeout_minutes * 60_000,
      pre_publication_config_digest: PtcManager.Repository.Contract.publication_digest(contract),
      pre_publication_status: "pending",
      pre_publication_verified_sha: nil,
      pre_publication_exit_status: nil,
      pre_publication_output: nil,
      pre_publication_duration_ms: nil,
      pre_publication_verified_at: nil
    ]
  end

  defp pre_publication_audit_details(nil), do: %{}

  defp pre_publication_audit_details(contract) do
    %{
      "pre_publication_bootstrap_command" => contract.bootstrap_command,
      "pre_publication_bootstrap_timeout_ms" => contract.bootstrap_timeout_minutes * 60_000,
      "pre_publication_command" => contract.before_publish_command,
      "pre_publication_timeout_ms" => contract.verification_timeout_minutes * 60_000,
      "pre_publication_config_digest" =>
        PtcManager.Repository.Contract.publication_digest(contract)
    }
  end

  defp pre_publication_matches?(job, nil) do
    is_nil(job.pre_publication_bootstrap_command) and
      is_nil(job.pre_publication_bootstrap_timeout_ms) and
      is_nil(job.pre_publication_command) and is_nil(job.pre_publication_timeout_ms) and
      is_nil(job.pre_publication_config_digest)
  end

  defp pre_publication_matches?(job, contract) do
    job.pre_publication_bootstrap_command == contract.bootstrap_command and
      job.pre_publication_bootstrap_timeout_ms == contract.bootstrap_timeout_minutes * 60_000 and
      job.pre_publication_command == contract.before_publish_command and
      job.pre_publication_timeout_ms == contract.verification_timeout_minutes * 60_000 and
      job.pre_publication_config_digest ==
        PtcManager.Repository.Contract.publication_digest(contract)
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

  defp create_or_refresh_unpublished_publication!(job, attrs) do
    case Repo.get_by(PrPublication, job_id: job.id) do
      nil ->
        %PrPublication{}
        |> PrPublication.changeset(attrs)
        |> Repo.insert!()

      %PrPublication{source: "broker", pr_number: nil, state: state} = publication
      when state in ["queued", "publishing", "blocked"] ->
        publication
        |> PrPublication.changeset(
          Map.merge(attrs, %{
            attempt_count: 0,
            attempt_token: nil,
            attempt_expires_at: nil,
            next_attempt_at: nil,
            last_error: nil
          })
        )
        |> Repo.update!()

      %PrPublication{} ->
        Repo.rollback(:publication_already_exists)
    end
  end

  defp eligible_result_jobs(query, now) do
    query =
      where(
        query,
        [job],
        is_nil(job.review_state) or
          job.review_state not in ["paused", "manual", "cancelled", "resume_pending", "running"]
      )

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

  defp latest_agent_actions(action_key) do
    AgentAction
    |> where([action], action.action_key == ^action_key)
    |> order_by([action], desc: action.inserted_at, desc: action.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn action, actions ->
      Map.put_new(actions, {action.target_type, action.target_id}, action)
    end)
  end

  defp retrospective_issue_actions do
    AgentAction
    |> where([action], action.action_key == "create_retrospective_issue")
    |> order_by([action], desc: action.inserted_at, desc: action.id)
    |> Repo.all()
    |> Enum.group_by(& &1.target_id)
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
        worker = agent_action_worker!(candidate, now)

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

        %AgentRun{}
        |> AgentRun.changeset(%{
          worker_id: worker.id,
          agent_action_id: candidate.id,
          role:
            if(candidate.action_key in @repair_action_keys, do: "implementer", else: "manager"),
          state: if(candidate.action_key in @repair_action_keys, do: "starting", else: "working"),
          status_text:
            if(candidate.action_key in @repair_action_keys,
              do: "Waiting for Herdr to create the pull-request repair session.",
              else: "Running #{candidate.action_key |> String.replace("_", " ")}."
            ),
          started_at: now,
          last_heartbeat_at: now,
          fencing_token: attempt_count,
          worker_incarnation_id: worker.worker_incarnation_id,
          herdr_incarnation_id: worker.herdr_incarnation_id,
          coordinator_incarnation_id: worker.coordinator_incarnation_id
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

        AgentAction
        |> preload([:repository, :automation_definition_version])
        |> Repo.get!(candidate.id)
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

        {run_state, status_text, ended_at} = retained_action_run_state(action, run, state, now)

        run
        |> AgentRun.changeset(%{
          state: run_state,
          status_text: status_text,
          last_heartbeat_at: now,
          ended_at: ended_at
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
      {:ok, action} ->
        _ = PtcManager.Automations.reconcile_invocation(action)
        notify_and_return({:ok, action})

      {:error, reason} ->
        {:error, reason}
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

    {run_state, status_text, ended_at} = retained_action_run_state(action, run, state, now)

    run
    |> AgentRun.changeset(%{
      state: run_state,
      status_text: status_text,
      last_heartbeat_at: now,
      ended_at: ended_at
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

  defp agent_action_worker!(%AgentAction{action_key: action_key} = action, now)
       when action_key in @repair_action_keys do
    if not Application.get_env(:ptc_manager, :dispatch_enabled, false) do
      get_or_create_agent_action_worker!(now)
    else
      herdr_agent_action_worker!(action, now)
    end
  end

  defp agent_action_worker!(
         %AgentAction{
           automation_definition_version: %{execution_profile: profile}
         } = action,
         now
       )
       when profile in ["generic_ephemeral", "ephemeral_investigation"] do
    if Application.get_env(:ptc_manager, :dispatch_enabled, false),
      do: generic_herdr_action_worker!(action, now),
      else: get_or_create_agent_action_worker!(now)
  end

  defp agent_action_worker!(%AgentAction{}, now), do: get_or_create_agent_action_worker!(now)

  defp generic_herdr_action_worker!(action, now) do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")

    worker =
      case Repo.get_by(Worker, worker_key: "herdr:#{session}") do
        %Worker{status: "online"} = worker -> worker
        _worker -> Repo.rollback(:worker_unavailable)
      end

    resource_class = action.automation_definition_version.resource_class

    capacity =
      if resource_class == "heavy",
        do: Application.get_env(:ptc_manager, :heavy_agent_capacity, 1),
        else: Application.get_env(:ptc_manager, :light_agent_capacity, 2)

    result =
      with :ok <- heavy_action_priority_available(resource_class) do
        if resource_class == "heavy" do
          dispatch_capacity_available(Repo, worker, capacity, now)
        else
          generic_action_capacity_available(Repo, worker, resource_class, capacity, now)
        end
      end

    case result do
      :ok -> worker
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp heavy_action_priority_available("heavy"), do: heavy_delivery_priority_unlocked()
  defp heavy_action_priority_available("light"), do: :ok

  defp generic_action_capacity_available(repo, worker, resource_class, capacity, now) do
    Worker
    |> where([candidate], candidate.id == ^worker.id)
    |> repo.update_all(set: [updated_at: now])

    active_count =
      AgentRun
      |> join(:inner, [run], candidate in AgentAction, on: candidate.id == run.agent_action_id)
      |> join(
        :left,
        [run, candidate],
        version in assoc(candidate, :automation_definition_version)
      )
      |> where(
        [run, _candidate, version],
        run.worker_id == ^worker.id and run.state in ^@capacity_run_states and
          version.resource_class == ^resource_class
      )
      |> repo.aggregate(:count)

    if active_count < capacity, do: :ok, else: {:error, :dispatch_capacity}
  end

  defp herdr_agent_action_worker!(%AgentAction{action_key: action_key} = action, now) do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")
    worker_key = "herdr:#{session}"

    worker =
      case Repo.get_by(Worker, worker_key: worker_key) do
        %Worker{status: "online"} = worker ->
          if worker_admitted?(worker), do: worker, else: Repo.rollback(:worker_unavailable)

        _worker ->
          Repo.rollback(:worker_unavailable)
      end

    if action_key == "repair_pr" and
         repository_merge_locked_except?(action.repository_id, action.id),
       do: Repo.rollback(:merge_priority)

    if action_key == @merge_action_key and repository_merge_precedes?(action),
      do: Repo.rollback(:merge_priority)

    if action_key == @merge_action_key and repository_writing_job_active?(action.repository_id),
      do: Repo.rollback(:merge_waiting_for_active_work)

    capacity =
      case worker.capabilities["implementation_slots"] do
        value when is_integer(value) and value > 0 -> value
        _value -> Repo.rollback(:worker_has_no_implementation_capacity)
      end

    if managed_repair_action?(action) do
      worker
    else
      case dispatch_capacity_available(Repo, worker, capacity, now) do
        :ok -> worker
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp retained_action_run_state(action, run, state, now) do
    publication =
      if action.action_key in @repair_action_keys and action.target_type == "pull_request",
        do: Repo.get(PrPublication, action.target_id)

    cond do
      # A repair that resumed a job's retained implementer runs in that agent;
      # the job's own run keeps representing it. Leaving this duplicate open
      # produces a record nothing reconciles, which then holds deployments.
      duplicate_of_retained_job_run?(run) ->
        if state == "done",
          do:
            {"done",
             "Completed #{String.replace(action.action_key, "_", " ")}; the retained implementer keeps its session.",
             now},
          else: {"failed", "The action failed; the retained implementer keeps its session.", now}

      action.action_key in @repair_action_keys and is_binary(run.herdr_workspace) and
        match?(%PrPublication{pr_state: "open"}, publication) and state == "done" ->
        {"waiting", "Repair turn finished; retained while the PR remains open.", nil}

      action.action_key in @repair_action_keys and is_binary(run.herdr_workspace) and
          match?(%PrPublication{pr_state: "open"}, publication) ->
        {"blocked", "The retained PR agent needs maintainer attention.", nil}

      state == "done" ->
        {"done", "Completed #{String.replace(action.action_key, "_", " ")}.", now}

      true ->
        {"failed", "The action failed; details are retained in PtcManager.", now}
    end
  end

  defp duplicate_of_retained_job_run?(%AgentRun{agent_name: name} = run) when is_binary(name) do
    AgentRun
    |> where(
      [other],
      other.id != ^run.id and other.agent_name == ^name and not is_nil(other.job_id)
    )
    |> Repo.exists?()
  end

  defp duplicate_of_retained_job_run?(_run), do: false

  defp active_merge_repository_ids do
    AgentAction
    |> where(
      [action],
      action.action_key == @merge_action_key and
        action.state in ["queued", "running", "sync_pending"]
    )
    |> select([action], action.repository_id)
  end

  defp active_writing_repository_ids do
    released_reviews = released_review_job_ids()

    Job
    |> where([job], job.state in ^@capacity_job_states and job.id not in ^released_reviews)
    |> select([job], job.repository_id)
  end

  defp agent_action_lane(query, :planning) do
    query
    |> join(:left, [action], version in assoc(action, :automation_definition_version),
      as: :automation_version
    )
    |> where(
      [action, automation_version: version],
      version.queue_lane == "planning" or
        (is_nil(version.id) and action.action_key in ^@planning_action_keys)
    )
  end

  defp agent_action_lane(query, :writing) do
    query
    |> join(:left, [action], version in assoc(action, :automation_definition_version),
      as: :automation_version
    )
    |> where(
      [action, automation_version: version],
      version.queue_lane == "writing" or
        (is_nil(version.id) and action.action_key not in ^@planning_action_keys)
    )
  end

  defp agent_action_lane(query, :any), do: query

  defp agent_action_resource_class(query, :any), do: query

  defp agent_action_resource_class(query, resource_class)
       when resource_class in ["light", "heavy"] do
    version_ids =
      from version in PtcManager.Automations.DefinitionVersion,
        where: version.resource_class == ^resource_class,
        select: version.id

    case resource_class do
      "heavy" ->
        where(
          query,
          [action],
          action.automation_definition_version_id in subquery(version_ids) or
            (is_nil(action.automation_definition_version_id) and
               action.action_key in ^@legacy_heavy_action_keys)
        )

      "light" ->
        where(
          query,
          [action],
          action.automation_definition_version_id in subquery(version_ids) or
            (is_nil(action.automation_definition_version_id) and
               action.action_key not in ^@legacy_heavy_action_keys)
        )
    end
  end

  defp repository_dispatch_unlocked(repository_id) do
    if repository_merge_locked?(repository_id), do: {:error, :merge_priority}, else: :ok
  end

  defp heavy_delivery_priority_unlocked do
    if heavy_delivery_action_active?(), do: {:error, :delivery_priority}, else: :ok
  end

  defp heavy_delivery_action_active? do
    AgentAction
    |> where(
      [action],
      action.action_key in ^@repair_action_keys and
        action.state in ["queued", "running", "sync_pending"]
    )
    |> Repo.exists?()
  end

  defp repository_merge_locked_except?(repository_id, action_id) do
    AgentAction
    |> where(
      [action],
      action.repository_id == ^repository_id and action.id != ^action_id and
        action.action_key == @merge_action_key and
        action.state in ["queued", "running", "sync_pending"]
    )
    |> Repo.exists?()
  end

  defp repository_merge_precedes?(action) do
    AgentAction
    |> where(
      [candidate],
      candidate.repository_id == ^action.repository_id and candidate.id != ^action.id and
        candidate.action_key == @merge_action_key and
        (candidate.state in ["running", "sync_pending"] or
           (candidate.state == "queued" and
              (candidate.requested_at < ^action.requested_at or
                 (candidate.requested_at == ^action.requested_at and candidate.id < ^action.id))))
    )
    |> Repo.exists?()
  end

  defp repository_writing_job_active?(repository_id) do
    released_reviews = released_review_job_ids()

    Job
    |> where(
      [job],
      job.repository_id == ^repository_id and job.state in ^@capacity_job_states and
        job.id not in ^released_reviews
    )
    |> Repo.exists?()
  end

  defp managed_repair_action?(%AgentAction{target_type: "pull_request", target_id: target_id}) do
    case Repo.get(PrPublication, target_id) do
      %PrPublication{job_id: job_id} when is_integer(job_id) -> true
      _publication -> false
    end
  end

  defp summarize_action_result(result), do: Jason.encode!(result)

  defp normalize_agent_action_insert(changeset) do
    if changeset.errors[:action_key],
      do: {:error, :agent_action_already_active},
      else: {:error, changeset}
  end

  defp current_dispatch_worker(repo, worker_key) do
    case repo.get_by(Worker, worker_key: worker_key) do
      %Worker{status: "online"} = worker ->
        if worker_admitted?(worker), do: {:ok, worker}, else: {:error, :worker_unavailable}

      _worker ->
        {:error, :worker_unavailable}
    end
  end

  defp worker_admitted?(%Worker{coordinator_incarnation_id: coordinator_incarnation_id}),
    do: coordinator_incarnation_id == RuntimeIncarnation.current()

  defp action_run_matches_worker_incarnation(run, worker, dispatch) do
    cond do
      run.worker_id != worker.id ->
        {:error, :stale_worker_incarnation}

      run.coordinator_incarnation_id != worker.coordinator_incarnation_id ->
        {:error, :stale_worker_incarnation}

      run.worker_incarnation_id != worker.worker_incarnation_id ->
        {:error, :stale_worker_incarnation}

      run.herdr_incarnation_id != worker.herdr_incarnation_id ->
        {:error, :stale_worker_incarnation}

      is_binary(run.external_key) and run.external_key != dispatch.external_key ->
        {:error, :stale_herdr_session}

      true ->
        :ok
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

  defp expire_job_lease(%Job{review_state: state}, _lease_now, _lifecycle_now)
       when state in ~w(paused manual cancelled resume_pending running), do: false

  defp expire_job_lease(%Job{state: "idle"} = job, lease_now, lifecycle_now) do
    message =
      "The implementation agent remained idle past its deadline; its partial worktree was preserved."

    case do_release_idle_job(
           job.id,
           {job.fencing_token, lease_now},
           "coordinator",
           message,
           lifecycle_now
         ) do
      {:ok, _job} -> true
      {:error, _reason} -> false
    end
  end

  defp expire_job_lease(job, lease_now, lifecycle_now) do
    Repo.transaction(fn ->
      {updated, _rows} =
        Job
        |> where(
          [candidate],
          candidate.id == ^job.id and candidate.fencing_token == ^job.fencing_token and
            candidate.state in ["starting", "working", "idle", "blocked"] and
            candidate.lease_expires_at <= ^lease_now
        )
        |> Repo.update_all(
          set: [
            state: "reconciling",
            lease_expires_at: nil,
            reconciling_at: lease_now,
            absence_observed_at: nil,
            last_error: "The worker lease expired; remote activity must be reconciled.",
            updated_at: lifecycle_now
          ]
        )

      if updated == 1 do
        mark_allocation!(job.id, %{
          state: "attention",
          last_used_at: lifecycle_now,
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

  defp do_release_idle_job(job_id, expiry_guard, actor, message, now) do
    Repo.transaction(fn ->
      query =
        Job
        |> where([job], job.id == ^job_id and job.state == "idle")
        |> maybe_guard_idle_expiry(expiry_guard)

      {updated, _rows} =
        query
        |> Repo.update_all(
          set: [
            state: "lost",
            lease_expires_at: nil,
            ended_at: now,
            last_error: message,
            updated_at: now
          ]
        )

      if updated != 1, do: Repo.rollback(:job_not_releasable)

      job = Repo.get!(Job, job_id)

      AgentRun
      |> where(
        [run],
        run.job_id == ^job_id and run.fencing_token == ^job.fencing_token and
          run.state in ["queued", "starting", "working", "idle", "blocked", "unknown"]
      )
      |> Repo.update_all(
        set: [
          state: "lost",
          status_text: message,
          last_heartbeat_at: now,
          ended_at: now,
          updated_at: now
        ]
      )

      mark_allocation!(job_id, %{
        state: "attention",
        last_used_at: now,
        last_error: message
      })

      insert_audit!(%{
        actor: actor,
        action: "job.idle_slot_released",
        target_type: "job",
        target_id: job_id,
        details: %{
          "fencing_token" => job.fencing_token,
          "worktree_preserved" => true,
          "reason" => message
        }
      })

      job
    end)
  end

  defp maybe_guard_idle_expiry(query, nil), do: query

  defp maybe_guard_idle_expiry(query, {fencing_token, lease_now}) do
    where(
      query,
      [job],
      job.fencing_token == ^fencing_token and not is_nil(job.lease_expires_at) and
        job.lease_expires_at <= ^lease_now
    )
  end

  defp insert_audit!(attrs), do: %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert!()
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp rejection_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp rejection_error(reason), do: bounded_error(reason)
  defp setup_error(%{state: "passed"}), do: nil
  defp setup_error(%{error: reason}), do: bounded_error(reason)
  defp setup_error(_report), do: "workspace_setup_failed"

  defp workspace_setup_evidence(report) do
    %{
      workspace_setup_state: Map.fetch!(report, :state),
      workspace_setup_script: Map.get(report, :script),
      workspace_setup_source_sha: Map.get(report, :source_sha),
      workspace_setup_started_at: Map.fetch!(report, :started_at),
      workspace_setup_ended_at: Map.fetch!(report, :ended_at),
      workspace_setup_duration_ms: Map.fetch!(report, :duration_ms),
      workspace_setup_exit_status: Map.get(report, :exit_status),
      workspace_setup_output: Map.get(report, :output, ""),
      workspace_setup_output_truncated: Map.get(report, :output_truncated, false),
      workspace_setup_cache_state: Map.get(report, :cache_state),
      workspace_setup_phase_durations: Map.get(report, :phase_durations, %{})
    }
  end

  defp bounded_error(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp bounded_error(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 500)

  defp configured_agent_capacity,
    do: Application.get_env(:ptc_manager, :heavy_agent_capacity, 1)

  # The automation version captured at approval chooses the agent kind, so
  # editing the selector later cannot change work that is already queued.
  defp implementation_profile(%Job{execution_settings: %{"kind" => kind}}),
    do: PtcManager.AgentProfiles.select(%{"mode" => "require", "preferred_kind" => kind})

  defp implementation_profile(%Job{automation_definition_version: %{agent_selector: selector}}),
    do: PtcManager.AgentProfiles.select(selector)

  defp implementation_profile(%Job{}), do: PtcManager.AgentProfiles.select(%{})

  defp notify_and_return(result) do
    notify_changed(__MODULE__)
    result
  end

  defp issue_is_open(%Issue{state: "open"}), do: :ok
  defp issue_is_open(%Issue{}), do: {:error, :issue_closed}

  # An issue with sub-issues is a collection: its children are implemented, it
  # is not. Unknown structure fails closed exactly as unknown dependencies do.
  @doc false
  def issue_not_collection(%Issue{structure_projected: false}),
    do: {:error, :issue_structure_unknown}

  def issue_not_collection(%Issue{} = issue) do
    if Issue.collection?(issue), do: {:error, :issue_is_collection}, else: :ok
  end

  defp issue_unclaimed(%Issue{github_assignment_projected: false}),
    do: {:error, :issue_claim_unknown}

  defp issue_unclaimed(%Issue{
         github_assignment_projected: true,
         github_assignees: %{"logins" => []}
       }),
       do: :ok

  defp issue_unclaimed(%Issue{
         github_assignment_projected: true,
         github_assignees: %{"logins" => logins}
       })
       when is_list(logins),
       do: {:error, :issue_claimed}

  defp issue_unclaimed(%Issue{}), do: {:error, :issue_claim_unknown}

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

  defp issue_dependencies_resolved(_repo, %Issue{dependency_unknown_count: count})
       when count > 0,
       do: {:error, :issue_dependencies_unresolved}

  defp issue_dependencies_resolved(repo, %Issue{} = issue) do
    dependencies =
      IssueDependency
      |> where([dependency], dependency.issue_id == ^issue.id)
      |> join(:left, [dependency], blocker in Issue,
        on: blocker.id == dependency.blocking_issue_id
      )
      |> select([dependency, blocker], {dependency, blocker})
      |> repo.all()

    cycles = dependency_cycles([issue.id])

    if is_nil(Map.get(cycles, issue.id)) and
         Enum.all?(dependencies, fn {dependency, blocker} ->
           dependency_satisfied?(dependency, blocker)
         end) do
      :ok
    else
      {:error, :issue_dependencies_unresolved}
    end
  end

  defp issue_dependency_projection_matches(
         _repo,
         %Issue{dependencies_projected: false},
         _remote
       ),
       do: {:error, :issue_dependencies_unresolved}

  defp issue_dependency_projection_matches(_repo, _issue, %{dependency_overflow: true}),
    do: {:error, :issue_dependencies_unresolved}

  defp issue_dependency_projection_matches(
         _repo,
         %Issue{dependency_unknown_count: local_count},
         %{dependency_unknown_count: remote_count}
       )
       when local_count != remote_count,
       do: {:error, :issue_dependencies_unresolved}

  defp issue_dependency_projection_matches(repo, issue, remote) do
    projected_keys =
      IssueDependency
      |> where([dependency], dependency.issue_id == ^issue.id)
      |> select(
        [dependency],
        {dependency.blocking_repository_full_name, dependency.blocking_issue_number}
      )
      |> repo.all()
      |> Enum.sort()

    remote_keys =
      remote.blocking_issues
      |> Enum.map(&{&1.repository_full_name, &1.number})
      |> Enum.sort()

    if projected_keys == remote_keys,
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
    |> preload([:blocking_issue, :blocking_repository])
    |> Repo.all()
    |> Enum.group_by(& &1.issue_id, fn dependency ->
      %{
        number: dependency.blocking_issue_number,
        repository_full_name: dependency.blocking_repository_full_name,
        title: dependency.blocking_title,
        html_url: dependency.blocking_html_url,
        state: dependency.blocking_state,
        state_reason: dependency.blocking_state_reason,
        lookup_state: dependency.lookup_state,
        issue: dependency.blocking_issue,
        active_job: dependency.blocking_issue && Map.get(jobs, dependency.blocking_issue.id)
      }
    end)
  end

  defp dependency_cycles(issue_ids) do
    issues =
      Issue
      |> preload([:repository, :dependencies])
      |> Repo.all()

    cycles = DependencyGraph.cycles(issues)
    Map.take(cycles, issue_ids)
  end

  defp dependency_satisfied?(%IssueDependency{lookup_state: "resolved"} = dependency, _blocker),
    do:
      dependency.blocking_state == "closed" and
        dependency.blocking_state_reason == "completed"

  defp dependency_satisfied?(_dependency, _blocker), do: false

  defp latest_jobs([]), do: %{}

  defp latest_jobs(issue_ids) do
    Job
    |> where([job], job.issue_id in ^issue_ids)
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn job, jobs -> Map.put_new(jobs, job.issue_id, job) end)
  end

  defp normalize_approval_result({:error, reason}), do: {:error, reason}

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
