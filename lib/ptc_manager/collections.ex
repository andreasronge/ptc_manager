defmodule PtcManager.Collections do
  @moduledoc """
  Collection runs: unattended delivery of an issue that has GitHub sub-issues.

  A run is the maintainer's one decision that a collection may be delivered
  without a click per member. Deterministic code then admits each member when
  its dependencies close, merges a member pull request at the exact reviewed
  head once CI is green, hands the merged retrospective to the remaining
  members through an agent, spends one bounded recovery per stuck mode, and
  escalates everything else through one comment on the umbrella issue.

  Every automatic effect is recorded as a `Step` in the same transaction that
  causes it, so a bound is a row and a lost race is a no-op. The reconciler is
  idempotent and runs after GitHub syncs, after pull-request status changes,
  after agent actions finish, and once a minute as a backstop.
  """

  import Ecto.Query
  require Logger

  alias PtcManager.{ExecutionProfiles, Gateway, MaintainerActions, Operations, Publications, Repo}
  alias PtcManager.{OperationalMode, RepoTransaction, Reviews}
  alias PtcManager.Collections.{Member, Run, Step, Structure}
  alias PtcManager.Operations.{AgentAction, Issue, Job, PrPublication, Repository}

  @actor "system:collection"
  @outstanding_states ~w(queued running sync_pending)
  @max_action_attempts 2
  @max_closeout_attempts 3
  @live_job_states ~w(queued starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open)

  def actor, do: @actor

  ## Queries

  @doc "The live run of an umbrella issue, or nil."
  def current_run(issue_id) when is_integer(issue_id) do
    Run
    |> where([run], run.issue_id == ^issue_id and run.state in ^Run.live_states())
    |> preload([:members, :steps])
    |> Repo.one()
  end

  @doc "The live runs of many umbrella issues, keyed by issue id, for the Planning page."
  def live_runs_by_issue([]), do: %{}

  def live_runs_by_issue(issue_ids) when is_list(issue_ids) do
    Run
    |> where([run], run.issue_id in ^issue_ids and run.state in ^Run.live_states())
    |> Repo.all()
    |> Map.new(&{&1.issue_id, &1})
  end

  def get_run!(id), do: Run |> preload([:members, :steps, :issue, :repository]) |> Repo.get!(id)

  @doc "Every member of a run with its classification, for the console."
  def member_statuses(%Run{} = run) do
    umbrella = Repo.get!(Issue, run.issue_id) |> Repo.preload(:repository)
    run = Repo.preload(run, [:members, :steps])
    Enum.map(Structure.members(umbrella), &classify(&1, run))
  end

  ## Maintainer decisions

  @doc """
  Starts a run for an umbrella issue.

  Requires an active mode, an enabled repository, an open umbrella whose
  structure passes every invariant, and no live run. Members already merged
  get a baseline handoff step so no handoff runs for history.
  """
  def start(issue_id, attrs, actor)
      when is_integer(issue_id) and is_map(attrs) and is_binary(actor) and actor != "" do
    with :ok <- OperationalMode.authorize_ordinary_work() do
      result =
        RepoTransaction.immediate(fn ->
          issue = Issue |> Repo.get(issue_id) |> Repo.preload(:repository)

          cond do
            is_nil(issue) -> Repo.rollback(:not_found)
            not issue.repository.enabled -> Repo.rollback(:repository_disabled)
            issue.state != "open" -> Repo.rollback(:issue_closed)
            not Issue.collection?(issue) -> Repo.rollback(:not_a_collection)
            current_run(issue.id) != nil -> Repo.rollback(:run_already_live)
            true -> :ok
          end

          with :ok <- validate_structure(issue) do
            now = utc_now()

            run =
              %Run{}
              |> Run.changeset(%{
                repository_id: issue.repository_id,
                issue_id: issue.id,
                state: "active",
                auto_merge: Map.get(attrs, :auto_merge, true) == true,
                auto_recover: Map.get(attrs, :auto_recover, true) == true,
                actor: actor,
                started_at: now
              })
              |> Repo.insert!()

            members = Structure.members(issue)
            Enum.each(members, &insert_member!(run, &1.number, &1.issue, "start"))

            # Publications merged before the run exist as history, not as
            # handoffs to run: record their steps so the reconciler skips them.
            for member <- members,
                %Issue{} = member_issue <- [member.issue],
                publication <- merged_publications(member_issue) do
              record_step!(run, "handoff", "#{publication.id}:attempt:1", actor, %{})
            end

            ExecutionProfiles.audit(
              actor,
              "collection_run.started",
              run.id,
              %{
                issue_number: issue.number,
                auto_merge: run.auto_merge,
                auto_recover: run.auto_recover,
                members: Enum.map(members, & &1.number)
              },
              "collection_run"
            )

            run
          end
        end)

      case result do
        {:ok, run} ->
          Operations.notify_changed(__MODULE__)
          PtcManager.GitHub.Poller.wake()
          {:ok, run}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Pauses a run by hand; queued collection actions are cancelled and their steps removed."
  def pause(run_id, actor) when is_integer(run_id) and is_binary(actor) and actor != "" do
    transition(run_id, actor, fn %Run{state: "active"} = run ->
      cancel_queued_actions(run, actor)

      run
      |> Run.changeset(%{
        state: "paused",
        pause_sequence: run.pause_sequence + 1,
        pause_kind: nil,
        pause_reason: "Paused by #{actor}.",
        pause_scope: "manual:#{run.pause_sequence + 1}",
        paused_issue_number: nil,
        pause_reference_id: nil,
        paused_at: utc_now(),
        escalation_pending: false
      })
      |> Repo.update!()
    end)
  end

  @doc """
  Lifts the current pause as an explicit override.

  The override is scoped to the pause it lifts: the reconciler will not pause
  again for that scope, while a new job, head, generation, or action makes a
  new scope that is judged afresh. Not offered for structural drift, which
  only `accept_changes/2` resolves.
  """
  def resume(run_id, actor) when is_integer(run_id) and is_binary(actor) and actor != "" do
    transition(run_id, actor, fn
      %Run{state: "paused", pause_kind: "membership_changed"} ->
        Repo.rollback(:accept_changes_required)

      %Run{state: "paused"} = run ->
        if is_binary(run.pause_scope),
          do: record_step!(run, "override", run.pause_scope, actor, %{})

        # A queued escalation would post a comment about a pause that no
        # longer exists.
        cancel_queued_actions(run, actor)
        activate(run)

      _run ->
        Repo.rollback(:run_not_paused)
    end)
  end

  @doc """
  Accepts GitHub's current sub-issue list as the authorized membership.

  Refuses to drop a member that has an active job or an open publication, and
  requires the accepted set to pass the structure invariants.
  """
  def accept_changes(run_id, actor)
      when is_integer(run_id) and is_binary(actor) and actor != "" do
    transition(run_id, actor, fn %Run{state: "paused", pause_kind: "membership_changed"} = run ->
      umbrella = Repo.get!(Issue, run.issue_id)
      current = Structure.members(umbrella)
      current_numbers = MapSet.new(current, & &1.number)
      existing = Repo.all(from member in Member, where: member.run_id == ^run.id)

      # A member with work in flight cannot be dropped, whatever GitHub says.
      for member <- existing, not MapSet.member?(current_numbers, member.issue_number) do
        if member.issue_id && member_in_flight?(member.issue_id),
          do: Repo.rollback({:member_in_flight, member.issue_number})
      end

      with :ok <- validate_structure(umbrella) do
        for member <- existing,
            not MapSet.member?(current_numbers, member.issue_number),
            do: Repo.delete!(member)

        Enum.each(current, &insert_member!(run, &1.number, &1.issue, "accept"))
        record_step!(run, "override", run.pause_scope, actor, %{})
        cancel_queued_actions(run, actor)
        activate(run)
      end
    end)
  end

  @doc "Ends a run; queued collection actions are cancelled, running ones finish, GitHub is untouched."
  def cancel(run_id, actor) when is_integer(run_id) and is_binary(actor) and actor != "" do
    transition(run_id, actor, fn %Run{} = run ->
      unless Run.live?(run), do: Repo.rollback(:run_not_live)
      cancel_queued_actions(run, actor)
      end_run(run, "cancelled", "Cancelled by #{actor}.")
    end)
  end

  ## Admission gates, called inside the approval transaction and before dispatch

  @doc false
  def eligible(repo, %Issue{} = issue) do
    repository = repo.get!(Repository, issue.repository_id)
    run = parent_run(repo, issue)

    cond do
      not repository.enabled ->
        {:error, :repository_disabled}

      not match?(%Run{state: "active"}, run) ->
        {:error, :no_active_collection_run}

      not member?(repo, run, issue.number) ->
        {:error, :not_a_member}

      repo.exists?(from job in Job, where: job.issue_id == ^issue.id) ->
        {:error, :already_attempted}

      linked_publication?(repo, issue) ->
        {:error, :issue_has_pull_request}

      true ->
        :ok
    end
  end

  @doc false
  def dispatch_allowed(%Job{} = job, remote) do
    cond do
      not job.repository.enabled ->
        {:error, :repository_disabled}

      not match?(%Run{state: "active"}, parent_run(Repo, job.issue)) ->
        {:error, :no_active_collection_run}

      remote.workflow_label != "ptc:ready" or remote.workflow_label_conflict ->
        {:error, :issue_workflow_not_ready}

      not remote.structure_projected ->
        {:error, :issue_structure_unknown}

      remote.sub_issues["total"] > 0 ->
        {:error, :issue_is_collection}

      remote.github_assignees != %{"logins" => []} ->
        {:error, :issue_claimed}

      linked_publication?(Repo, job.issue) ->
        {:error, :issue_has_pull_request}

      true ->
        :ok
    end
  end

  ## Reconciliation

  @doc "Reconciles every enabled repository that has a live run."
  def reconcile_all do
    Run
    |> where([run], run.state in ^Run.live_states())
    |> select([run], run.repository_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.each(&reconcile/1)
  end

  @doc """
  Advances every live run of one repository by one idempotent pass.

  Every entry point comes through here, so the operational mode and the
  repository's enabled flag are checked once, and nothing is touched when
  either refuses.
  """
  def reconcile(repository_id) when is_integer(repository_id) do
    with :ok <- OperationalMode.authorize_ordinary_work(),
         %Repository{enabled: true} = repository <- Repo.get(Repository, repository_id) do
      Run
      |> where([run], run.repository_id == ^repository_id and run.state in ^Run.live_states())
      |> order_by([run], asc: run.id)
      |> Repo.all()
      |> Enum.each(fn run ->
        try do
          reconcile_run(run, repository)
        rescue
          error ->
            Logger.warning(
              "Collection run #{run.id} reconcile failed: #{Exception.message(error)}\n" <>
                Exception.format_stacktrace(__STACKTRACE__)
            )
        end
      end)

      :ok
    else
      _refused -> :ok
    end
  end

  defp reconcile_run(%Run{} = run, repository) do
    run = Repo.preload(run, [:members, :steps], force: true)
    umbrella = Issue |> Repo.get!(run.issue_id) |> Repo.preload(:repository)
    statuses = Enum.map(Structure.members(umbrella), &classify(&1, run))

    cond do
      run.state == "finishing" ->
        finishing_pass(run, umbrella, statuses)

      run.state == "paused" ->
        paused_pass(run, umbrella, statuses)

      true ->
        active_pass(run, umbrella, statuses, repository)
    end
  end

  # An active run: outstanding work first, then drift, then attention, then
  # the effects that need a quiet collection.
  defp active_pass(run, umbrella, statuses, repository) do
    adopt_created_members(run, umbrella)
    run = Repo.preload(run, [:members, :steps], force: true)
    outstanding = outstanding_actions(run)

    cond do
      umbrella.state == "closed" ->
        if Enum.all?(statuses, &(&1.status == :closed_completed)) and outstanding == [],
          do:
            apply_end(run, "completed", "Every member was delivered and the umbrella is closed."),
          else: apply_end(run, "cancelled", "umbrella_closed")

      drifted?(run, umbrella) ->
        apply_pause(run, %{
          kind: "membership_changed",
          reason: "GitHub's sub-issues no longer match the members this run was started with.",
          scope:
            "membership:#{umbrella |> Structure.member_numbers() |> Enum.sort() |> Enum.join(",")}"
        })

      match?({:attention, _}, first_attention(run, statuses)) ->
        {:attention, status} = first_attention(run, statuses)
        recover_or_pause(run, status)

      outstanding != [] ->
        :ok

      true ->
        quiet_pass(run, umbrella, statuses, repository)
    end
  end

  defp quiet_pass(run, umbrella, statuses, repository) do
    cond do
      exhausted_handoff(run, statuses) != nil ->
        {status, action} = exhausted_handoff(run, statuses)

        apply_pause(run, %{
          kind: "action_failed",
          reason: "The handoff after ##{status.number} merged failed twice.",
          member: status.number,
          reference_id: action.id,
          scope: "action:#{action.id}"
        })

      handoff_due(run, statuses) != nil ->
        {status, attempt} = handoff_due(run, statuses)
        enqueue_handoff(run, umbrella, status, statuses, attempt)

      merge_candidate(run, statuses) != nil ->
        enqueue_merge(run, merge_candidate(run, statuses), repository)

      admissible(run, statuses) != [] ->
        Enum.each(admissible(run, statuses), &admit(run, &1))

      Enum.all?(statuses, &(&1.status == :closed_completed)) and statuses != [] ->
        closeout_or_finish(run, umbrella, statuses)

      true ->
        :ok
    end
  end

  defp paused_pass(run, umbrella, statuses) do
    cond do
      umbrella.state == "closed" ->
        apply_end(run, "cancelled", "umbrella_closed")

      pause_cleared?(run, umbrella, statuses) ->
        apply_transition(run, fn current -> activate(current) end, "collection_run.resumed", %{
          reason: "condition cleared"
        })

      run.escalation_pending and umbrella.state == "open" and
          outstanding_umbrella_actions(run, umbrella) == [] ->
        enqueue_escalation(run, umbrella)

      true ->
        :ok
    end
  end

  defp finishing_pass(run, umbrella, _statuses) do
    if umbrella.state == "closed",
      do: apply_end(run, "completed", "Every member was delivered and the umbrella is closed."),
      else: :ok
  end

  ## Classification

  @doc false
  def classify(%{issue: nil} = member, _run) do
    status =
      case member do
        %{state: "closed", state_reason: "completed"} -> :closed_completed
        %{state: "closed"} -> :closed_other
        _open -> :waiting_sync
      end

    base(member, status, nil, nil)
  end

  def classify(%{issue: %Issue{state: "closed"} = issue} = member, _run) do
    status =
      if issue.github_state_reason == "completed", do: :closed_completed, else: :closed_other

    job = latest_job(issue)
    publication = job && job.pr_publication

    # A closed member keeps its job and publication visible, so a merge that
    # closed it can still be handed off, and a merge at a head the run never
    # authorized still waits for the maintainer.
    case publication && unauthorized_merge(publication) do
      %AgentAction{} = action ->
        base(member, :attention, job, publication)
        |> attention(
          "action_failed",
          "The pull request for ##{issue.number} was merged at a head the run did not authorize; review that merge before continuing.",
          action.id,
          "action:#{action.id}"
        )

      _authorized ->
        closed_member(member, status, issue, job, publication)
    end
  end

  def classify(%{issue: %Issue{} = issue} = member, run) do
    job = latest_job(issue)
    publication = job && job.pr_publication

    cond do
      is_nil(job) -> classify_unstarted(member, issue)
      true -> classify_job(member, issue, job, publication, run)
    end
  end

  defp closed_member(member, status, issue, job, publication) do
    base(member, status, job, publication)
    |> maybe_attention(
      status == :closed_other,
      "child_closed_without_completion",
      "##{issue.number} was closed as #{issue.github_state_reason || "unspecified"}, not completed.",
      issue.id,
      "member:#{issue.number}:closed:#{issue.github_state_reason}"
    )
  end

  defp classify_unstarted(member, issue) do
    resolved? = Operations.dependencies_resolved?(issue)

    cond do
      issue.workflow_label == "ptc:needs-decision" or issue.workflow_label_conflict ->
        base(member, :attention, nil, nil)
        |> attention(
          "child_needs_decision",
          "##{issue.number} needs a maintainer decision on GitHub.",
          issue.id,
          "member:#{issue.number}:label:#{issue.workflow_label}:#{issue.content_digest}"
        )

      issue.workflow_label == "ptc:blocked" and resolved? ->
        base(member, :attention, nil, nil)
        |> attention(
          "child_needs_decision",
          "##{issue.number} is labelled blocked although no member blocks it.",
          issue.id,
          "member:#{issue.number}:label:blocked:#{issue.content_digest}"
        )

      is_nil(issue.workflow_label) ->
        base(member, :attention, nil, nil)
        |> attention(
          "child_needs_decision",
          "##{issue.number} carries no workflow label.",
          issue.id,
          "member:#{issue.number}:label:none:#{issue.content_digest}"
        )

      not resolved? or issue.workflow_label == "ptc:blocked" ->
        base(member, :blocked_by_dependency, nil, nil)

      true ->
        base(member, :ready, nil, nil)
    end
  end

  defp classify_job(member, issue, job, publication, run) do
    cond do
      publication && publication.pr_state == "merged" ->
        # GitHub's merge is recorded as truth, but a merge at a head the run
        # never authorized is not delivery: it waits for the maintainer.
        case unauthorized_merge(publication) do
          nil ->
            base(member, :merged, job, publication)

          action ->
            base(member, :attention, job, publication)
            |> attention(
              "action_failed",
              "The pull request for ##{issue.number} was merged at a head the run did not authorize; review that merge before continuing.",
              action.id,
              "action:#{action.id}"
            )
        end

      job.state == "done" ->
        base(member, :merged, job, publication)

      publication && publication.pr_state == "closed" ->
        base(member, :attention, job, publication)
        |> attention(
          "child_attempt_failed",
          "The pull request for ##{issue.number} was closed without merging.",
          job.id,
          "member:#{issue.number}:job:#{job.id}:pr_closed"
        )

      job.review_state in ["paused", "manual"] and job.state in @live_job_states ->
        base(member, :attention, job, publication)
        |> attention(
          "child_review_held",
          review_hold_reason(issue, job),
          job.id,
          "member:#{issue.number}:job:#{job.id}:review:#{job.review_generation}"
        )

      job.state == "publish_blocked" ->
        base(member, :attention, job, publication)
        |> attention(
          "child_publication_blocked",
          "Publication of ##{issue.number} is blocked: #{job.last_error || "see the Delivery board"}.",
          job.id,
          "member:#{issue.number}:job:#{job.id}:publish_blocked"
        )

      publication != nil and publication.state == "published" and publication.pr_state == "open" ->
        classify_open_publication(member, issue, job, publication)

      job.state in @live_job_states ->
        base(member, :in_progress, job, publication)

      job.state == "failed" ->
        classify_failed(member, issue, job, publication, run)

      job.state in ["lost", "cancelled"] ->
        base(member, :attention, job, publication)
        |> attention(
          "child_attempt_failed",
          "The implementation of ##{issue.number} ended #{job.state}: #{job.last_error || "no detail"}.",
          job.id,
          "member:#{issue.number}:job:#{job.id}:#{job.state}"
        )

      true ->
        base(member, :in_progress, job, publication)
    end
  end

  defp classify_open_publication(member, issue, job, publication) do
    merge_action = latest_merge_action(publication)

    cond do
      publication.checks_state == "failure" or publication.mergeability == "conflicting" ->
        base(member, :attention, job, publication)
        |> attention(
          "child_merge_blocked",
          "The pull request for ##{issue.number} has #{publication_problem(publication)}; a repair would produce an unreviewed head.",
          publication.id,
          "member:#{issue.number}:publication:#{publication.id}:#{publication.remote_head_sha}:blocked"
        )

      is_binary(publication.head_sha) and is_binary(publication.remote_head_sha) and
          publication.head_sha != publication.remote_head_sha ->
        base(member, :attention, job, publication)
        |> attention(
          "child_merge_blocked",
          "The pull request for ##{issue.number} moved past the head PtcManager reviewed.",
          publication.id,
          "member:#{issue.number}:publication:#{publication.id}:#{publication.remote_head_sha}:moved"
        )

      merge_action_failed?(merge_action, publication) ->
        base(member, :attention, job, publication)
        |> attention(
          "child_merge_blocked",
          "The merge of ##{issue.number} at #{String.slice(publication.remote_head_sha || "", 0, 12)} did not finish: #{merge_action.last_error || "the agent reported the merge blocked"}.",
          publication.id,
          "member:#{issue.number}:publication:#{publication.id}:#{publication.remote_head_sha}:merge_failed"
        )

      true ->
        base(member, :pr_open, job, publication)
    end
  end

  defp classify_failed(member, issue, job, publication, run) do
    report = job.stop_report

    cond do
      is_map(report) and is_nil(job.stop_acknowledged_at) ->
        base(member, :attention, job, publication)
        |> attention(
          "child_attempt_failed",
          "The agent stopped on ##{issue.number}: #{PtcManager.Operations.StopReport.summary(report)}",
          job.id,
          "member:#{issue.number}:job:#{job.id}:stop"
        )
        |> Map.put(:stop_report, report)

      is_map(report) and step_exists?(run, "ask_on_issue", "member:#{issue.number}:attempt:") ->
        classify_asked(member, issue, job, publication, run)

      true ->
        base(member, :attention, job, publication)
        |> attention(
          "child_attempt_failed",
          "The implementation of ##{issue.number} failed: #{job.last_error || "no detail"}.",
          job.id,
          "member:#{issue.number}:job:#{job.id}:failed"
        )
    end
  end

  # The blocker was sent to the issue; what happens next depends on that action.
  defp classify_asked(member, issue, job, publication, run) do
    case action_attempt(run, "ask_on_issue", "member:#{issue.number}:attempt:") do
      {:outstanding, _action} ->
        base(member, :waiting_action, job, publication)

      {:exhausted, action} ->
        base(member, :attention, job, publication)
        |> attention(
          "action_failed",
          "Reporting the blocker of ##{issue.number} on GitHub failed twice.",
          action.id,
          "action:#{action.id}"
        )

      {:retry, _attempt} ->
        base(member, :attention, job, publication)
        |> attention(
          "action_failed",
          "Reporting the blocker of ##{issue.number} on GitHub failed.",
          job.id,
          "member:#{issue.number}:job:#{job.id}:ask_retry"
        )
        |> Map.put(:ask_retry, true)

      {:done, _action} ->
        base(member, :attention, job, publication)
        |> attention(
          "child_needs_decision",
          "##{issue.number} is waiting for the maintainer's answer on GitHub.",
          issue.id,
          "member:#{issue.number}:label:#{issue.workflow_label}:#{issue.content_digest}"
        )
    end
  end

  defp base(member, status, job, publication) do
    %{
      number: member.number,
      member: member,
      issue: member.issue,
      status: status,
      job: job,
      publication: publication,
      attention: nil
    }
  end

  defp attention(classified, kind, reason, reference_id, scope) do
    %{
      classified
      | status: :attention,
        attention: %{
          kind: kind,
          reason: reason,
          reference_id: reference_id,
          scope: scope,
          member: classified.number
        }
    }
  end

  defp maybe_attention(classified, false, _kind, _reason, _reference_id, _scope), do: classified

  defp maybe_attention(classified, true, kind, reason, reference_id, scope),
    do: attention(classified, kind, reason, reference_id, scope)

  defp review_hold_reason(issue, %Job{review_state: "manual"}),
    do: "##{issue.number} was taken over manually; the run does not override a maintainer."

  defp review_hold_reason(issue, job),
    do: "The review of ##{issue.number} is paused: #{job.last_error || "see the Delivery board"}."

  defp publication_problem(%PrPublication{checks_state: "failure"}), do: "failing checks"
  defp publication_problem(_publication), do: "a merge conflict"

  ## Attention: bounded recovery or pause

  defp first_attention(run, statuses) do
    statuses
    |> Enum.filter(&(&1.status == :attention))
    |> Enum.reject(&overridden?(run, &1.attention.scope))
    |> List.first()
    |> case do
      nil -> :none
      status -> {:attention, status}
    end
  end

  defp recover_or_pause(%Run{auto_recover: false} = run, status),
    do: apply_pause(run, status.attention)

  defp recover_or_pause(
         run,
         %{attention: %{kind: "child_attempt_failed"}, stop_report: report} = status
       )
       when is_map(report) do
    job = status.job

    case PtcManager.Operations.StopReport.primary_action(report) do
      :retry ->
        if report["progress"] == "none",
          do:
            spend(run, "retry", "member:#{status.number}", status, fn ->
              Operations.retry_stopped_job(job.id, @actor)
            end),
          else: apply_pause(run, status.attention)

      :ask_on_issue ->
        spend(run, "ask_on_issue", "member:#{status.number}:attempt:1", status, fn ->
          MaintainerActions.enqueue_blocked_issue_review(job.id, @actor)
        end)

      :none ->
        apply_pause(run, status.attention)
    end
  end

  defp recover_or_pause(run, %{attention: %{kind: "action_failed"}, ask_retry: true} = status) do
    job = status.job

    case action_attempt(run, "ask_on_issue", "member:#{status.number}:attempt:") do
      {:retry, attempt} ->
        spend(run, "ask_on_issue", "member:#{status.number}:attempt:#{attempt}", status, fn ->
          reopen_stop_and_ask(job)
        end)

      _other ->
        apply_pause(run, status.attention)
    end
  end

  defp recover_or_pause(run, %{attention: %{kind: "child_review_held"}, job: job} = status) do
    cond do
      job.review_state == "manual" ->
        apply_pause(run, status.attention)

      Reviews.retry_available?(job) ->
        spend(run, "review_retry", "member:#{status.number}", status, fn ->
          Reviews.decide(job.id, job.review_generation, "retry_review", %{}, @actor)
        end)

      true ->
        spend(run, "review_continue", "member:#{status.number}", status, fn ->
          Reviews.decide(
            job.id,
            job.review_generation,
            "continue",
            %{"extra_rounds" => 2, "profile" => "strong"},
            @actor
          )
        end)
    end
  end

  defp recover_or_pause(run, status), do: apply_pause(run, status.attention)

  # One recovery per scope: when the step exists the recovery was spent, and the
  # condition that is still here is the maintainer's.
  defp spend(run, kind, scope, status, effect) do
    if step_exists?(run, kind, scope) do
      apply_pause(run, status.attention)
    else
      result =
        RepoTransaction.immediate(fn ->
          current = Repo.get!(Run, run.id)
          if current.state != "active", do: Repo.rollback(:run_not_active)
          if step_exists?(current, kind, scope), do: Repo.rollback(:step_spent)

          case effect.() do
            {:ok, %Job{id: job_id}} ->
              record_step!(current, kind, scope, @actor, %{job_id: job_id})

            {:ok, %AgentAction{id: action_id}} ->
              record_step!(current, kind, scope, @actor, %{agent_action_id: action_id})

            {:ok, _other} ->
              record_step!(current, kind, scope, @actor, %{})

            {:error, reason} ->
              Repo.rollback({:recovery_failed, reason})
          end
        end)

      case result do
        {:ok, _step} ->
          audit(run, "collection_run.recovery_spent", %{
            kind: kind,
            scope: scope,
            member: status.number
          })

          Operations.notify_changed(__MODULE__)
          :ok

        {:error, {:recovery_failed, reason}} ->
          Logger.warning(
            "Collection run #{run.id}: #{kind} for #{scope} refused: #{inspect(reason)}"
          )

          apply_pause(run, status.attention)

        {:error, _reason} ->
          :ok
      end
    end
  end

  # A second blocker report needs the stop to be unacknowledged again; the
  # first attempt acknowledged it when it queued.
  defp reopen_stop_and_ask(job) do
    Job
    |> where([j], j.id == ^job.id)
    |> Repo.update_all(set: [stop_acknowledged_at: nil])

    MaintainerActions.enqueue_blocked_issue_review(job.id, @actor)
  end

  ## Effects that need a quiet collection

  defp exhausted_handoff(run, statuses) do
    statuses
    |> Enum.filter(&(&1.publication != nil and &1.publication.pr_state == "merged"))
    |> Enum.sort_by(& &1.publication.id)
    |> Enum.find_value(fn status ->
      case action_attempt(run, "handoff", "#{status.publication.id}:attempt:") do
        {:exhausted, action} -> {status, action}
        _other -> nil
      end
    end)
  end

  defp handoff_due(run, statuses) do
    statuses
    |> Enum.filter(&(&1.publication != nil and &1.publication.pr_state == "merged"))
    |> Enum.sort_by(& &1.publication.id)
    |> Enum.find_value(fn status ->
      case action_attempt(run, "handoff", "#{status.publication.id}:attempt:") do
        {:retry, attempt} -> {status, attempt}
        _other -> nil
      end
    end)
  end

  defp enqueue_handoff(run, umbrella, status, statuses, attempt) do
    publication = status.publication

    open_members =
      for %{issue: %Issue{state: "open"} = issue} <- statuses do
        %{
          number: issue.number,
          title: issue.title,
          workflow_label: issue.workflow_label,
          blockers: issue |> Structure.dependencies() |> Enum.map(& &1.blocking_issue_number)
        }
      end

    protected =
      for %{issue: %Issue{} = issue} = member_status <- statuses,
          member_status.status in [:in_progress, :pr_open, :waiting_action] or
            (member_status.status == :attention and member_status.job != nil),
          into: %{},
          do: {Integer.to_string(issue.number), issue.content_digest}

    apply_action(run, "handoff", "#{publication.id}:attempt:#{attempt}", fn ->
      MaintainerActions.enqueue_collection_action(
        "collection_handoff",
        umbrella.id,
        %{
          publication: publication,
          member: %{number: status.number},
          open_members: open_members,
          protected: protected
        },
        @actor
      )
    end)
  end

  defp merge_candidate(%Run{auto_merge: false}, _statuses), do: nil

  defp merge_candidate(run, statuses) do
    Enum.find(statuses, fn status ->
      status.status == :pr_open and mergeable_now?(status) and
        not step_exists?(run, "merge", merge_scope(status.publication))
    end)
  end

  defp mergeable_now?(%{job: job, publication: publication}) do
    publication.state == "published" and publication.pr_state == "open" and
      publication.checks_state in ["success", "none"] and publication.mergeability == "mergeable" and
      publication.head_sha == publication.remote_head_sha and
      Reviews.publication_allowed?(job, publication)
  end

  defp merge_scope(publication), do: "#{publication.id}:#{publication.remote_head_sha}"

  # A stale poll must not authorize a merge: the status is read again from
  # GitHub, recorded, and only a still-green publication is handed to the
  # merge agent. The head is immutable, so its checks cannot change underneath
  # the agent except by a re-run.
  defp enqueue_merge(run, status, _repository) do
    publication = status.publication
    client = Application.fetch_env!(:ptc_manager, :pull_request_client)

    with {:ok, fresh} <- Gateway.call(client, :status, [publication]),
         {:ok, %PrPublication{} = current} <-
           Publications.record_remote_status(publication.id, fresh),
         :ok <- check_mergeable(mergeable_now?(%{status | publication: current})),
         :ok <- check_unlocked(Operations.repository_merge_locked?(run.repository_id)) do
      apply_action(run, "merge", merge_scope(current), fn ->
        MaintainerActions.enqueue("merge_reviewed_pr", current.id, @actor)
      end)
    else
      {:error, reason} ->
        Logger.info(
          "Collection run #{run.id}: merge of publication #{publication.id} deferred: #{inspect(reason)}"
        )

        :ok

      other ->
        Logger.info(
          "Collection run #{run.id}: merge of publication #{publication.id} deferred: #{inspect(other)}"
        )

        :ok
    end
  end

  defp check_mergeable(true), do: :ok
  defp check_mergeable(false), do: {:error, :not_mergeable_now}
  defp check_unlocked(false), do: :ok
  defp check_unlocked(true), do: {:error, :merge_locked}

  defp admissible(run, statuses) do
    Enum.filter(statuses, fn status ->
      status.status == :ready and not step_exists?(run, "admit", "#{status.number}")
    end)
  end

  defp admit(run, status) do
    apply_action(run, "admit", "#{status.number}", fn ->
      Operations.approve_collection_issue(status.issue.id)
    end)
  end

  defp closeout_or_finish(run, umbrella, statuses) do
    case action_attempt(run, "closeout", "attempt:", @max_closeout_attempts) do
      {:retry, attempt} ->
        members =
          for %{issue: %Issue{} = issue} <- statuses,
              do: %{
                number: issue.number,
                title: issue.title,
                workflow_label: issue.workflow_label,
                blockers: []
              }

        apply_action(run, "closeout", "attempt:#{attempt}", fn ->
          MaintainerActions.enqueue_collection_action(
            "collection_closeout",
            umbrella.id,
            %{members: members},
            @actor
          )
        end)

      {:done, action} ->
        case action_outcome(action) do
          # It created the missing members; they were adopted and the run
          # continues, or it will close out again when they finish.
          "completed" -> :ok
          _decided -> apply_transition(run, &finish/1, "collection_run.finishing", %{})
        end

      {:exhausted, action} ->
        apply_pause(run, %{
          kind: "action_failed",
          reason: "The close-out of the collection failed #{@max_closeout_attempts} times.",
          member: nil,
          reference_id: action.id,
          scope: "action:#{action.id}"
        })

      _other ->
        :ok
    end
  end

  # Enqueues one collection-owned action and records its step atomically.
  defp apply_action(run, kind, scope, enqueue) do
    result =
      RepoTransaction.immediate(fn ->
        current = Repo.get!(Run, run.id)
        if current.state != "active", do: Repo.rollback(:run_not_active)
        if step_exists?(current, kind, scope), do: Repo.rollback(:step_spent)

        case enqueue.() do
          {:ok, %AgentAction{id: action_id}} ->
            record_step!(current, kind, scope, @actor, %{agent_action_id: action_id})

          {:ok, %Job{id: job_id}} ->
            record_step!(current, kind, scope, @actor, %{job_id: job_id})

          {:error, reason} ->
            Repo.rollback({:effect_refused, reason})
        end
      end)

    case result do
      {:ok, _step} ->
        audit(run, "collection_run.#{kind}", %{scope: scope})
        Operations.notify_changed(__MODULE__)
        :ok

      {:error, {:effect_refused, reason}} ->
        Logger.warning("Collection run #{run.id}: #{kind} #{scope} refused: #{inspect(reason)}")
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  ## Pauses, escalation, and clearing

  defp apply_pause(run, attention) do
    scope = attention[:scope]

    if overridden?(run, scope) do
      :ok
    else
      apply_transition(
        run,
        fn current ->
          if current.state != "active", do: Repo.rollback(:run_not_active)
          cancel_queued_actions(current, @actor)

          current
          |> Run.changeset(%{
            state: "paused",
            pause_sequence: current.pause_sequence + 1,
            pause_kind: attention[:kind],
            pause_reason: String.slice(attention[:reason] || "", 0, 1_000),
            pause_scope: scope,
            paused_issue_number: attention[:member],
            pause_reference_id: attention[:reference_id],
            paused_at: utc_now(),
            escalation_pending: true
          })
          |> Repo.update!()
        end,
        "collection_run.paused",
        %{kind: attention[:kind], reason: attention[:reason], scope: scope}
      )
    end
  end

  defp enqueue_escalation(run, umbrella) do
    prefix = "#{run.pause_sequence}:attempt:"

    case action_attempt(run, "escalation", prefix) do
      {:retry, attempt} when attempt <= @max_action_attempts ->
        result =
          RepoTransaction.immediate(fn ->
            current = Repo.get!(Run, run.id)
            if current.state != "paused", do: Repo.rollback(:run_not_paused)

            if step_exists?(current, "escalation", "#{prefix}#{attempt}"),
              do: Repo.rollback(:step_spent)

            case MaintainerActions.enqueue_collection_action(
                   "report_collection_blocker",
                   umbrella.id,
                   %{
                     member_number: current.paused_issue_number || umbrella.number,
                     reason: current.pause_reason || current.pause_kind || "paused",
                     console_url: console_url(umbrella)
                   },
                   @actor
                 ) do
              {:ok, action} ->
                current
                |> Run.changeset(%{escalation_pending: false})
                |> Repo.update!()

                record_step!(current, "escalation", "#{prefix}#{attempt}", @actor, %{
                  agent_action_id: action.id
                })

              {:error, reason} ->
                Repo.rollback({:effect_refused, reason})
            end
          end)

        case result do
          {:ok, _step} ->
            Operations.notify_changed(__MODULE__)

          {:error, reason} ->
            Logger.info("Collection run #{run.id}: escalation deferred: #{inspect(reason)}")
        end

        :ok

      _spent ->
        # Both attempts were spent; the console card is the notification.
        Run |> where([r], r.id == ^run.id) |> Repo.update_all(set: [escalation_pending: false])
        :ok
    end
  end

  defp pause_cleared?(%Run{pause_kind: nil}, _umbrella, _statuses), do: false

  defp pause_cleared?(%Run{pause_kind: "membership_changed"}, _umbrella, _statuses), do: false

  defp pause_cleared?(%Run{pause_kind: "umbrella_needs_decision"}, umbrella, _statuses),
    do: umbrella.workflow_label != "ptc:needs-decision"

  defp pause_cleared?(%Run{pause_kind: "action_failed"} = run, _umbrella, _statuses) do
    case Repo.get(AgentAction, run.pause_reference_id) do
      nil ->
        true

      action ->
        Repo.exists?(
          from newer in AgentAction,
            where:
              newer.action_key == ^action.action_key and newer.target_type == ^action.target_type and
                newer.target_id == ^action.target_id and newer.id > ^action.id and
                newer.state == "done"
        )
    end
  end

  defp pause_cleared?(run, _umbrella, statuses) do
    case Enum.find(statuses, &(&1.number == run.paused_issue_number)) do
      nil -> true
      status -> member_pause_cleared?(run, status)
    end
  end

  defp member_pause_cleared?(%Run{pause_kind: "child_attempt_failed"} = run, status) do
    status.status in [:closed_completed, :pr_open, :merged, :in_progress] or
      (status.job != nil and status.job.id != run.pause_reference_id) or
      (status.publication != nil and status.publication.pr_state == "open")
  end

  defp member_pause_cleared?(%Run{pause_kind: "child_review_held"} = run, status) do
    case status.job do
      nil -> true
      %Job{id: id} when id != run.pause_reference_id -> true
      %Job{review_state: review_state} -> review_state not in ["paused", "manual"]
    end
  end

  defp member_pause_cleared?(%Run{pause_kind: "child_publication_blocked"}, status),
    do: status.job == nil or status.job.state != "publish_blocked"

  # Cleared when the pull request is no longer open, its head moved, or the
  # same head is simply green again after a re-run; the classification shows
  # the last two as the attention scope changing or disappearing.
  defp member_pause_cleared?(%Run{pause_kind: "child_merge_blocked"} = run, status) do
    case status.publication do
      nil ->
        true

      publication ->
        publication.pr_state != "open" or status.attention == nil or
          status.attention.scope != run.pause_scope
    end
  end

  defp member_pause_cleared?(%Run{pause_kind: "child_needs_decision"}, status) do
    status.status == :closed_completed or
      (status.issue != nil and status.issue.state == "open" and
         status.issue.workflow_label == "ptc:ready" and not status.issue.workflow_label_conflict)
  end

  defp member_pause_cleared?(%Run{pause_kind: "child_closed_without_completion"}, status),
    do:
      status.status == :closed_completed or (status.issue != nil and status.issue.state == "open")

  defp member_pause_cleared?(_run, _status), do: false

  ## Membership

  defp drifted?(run, umbrella) do
    Structure.member_numbers(umbrella) != MapSet.new(run.members, & &1.issue_number)
  end

  # Issues a handoff or close-out created become members once GitHub reports
  # them as sub-issues. Only numbers the action itself claimed can join.
  defp adopt_created_members(run, umbrella) do
    github_numbers = Structure.member_numbers(umbrella)
    known = MapSet.new(run.members, & &1.issue_number)

    for %Step{kind: kind, agent_action_id: action_id} <- run.steps,
        kind in ["handoff", "closeout"],
        is_integer(action_id),
        %AgentAction{state: "done"} = action <- [Repo.get(AgentAction, action_id)],
        number <- action_created_numbers(action),
        MapSet.member?(github_numbers, number),
        not MapSet.member?(known, number) do
      issue = Repo.get_by(Issue, repository_id: run.repository_id, number: number)

      %Member{}
      |> Member.changeset(%{
        run_id: run.id,
        issue_number: number,
        issue_id: issue && issue.id,
        added_by: kind
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:run_id, :issue_number])
    end

    :ok
  end

  defp insert_member!(run, number, issue, added_by) do
    %Member{}
    |> Member.changeset(%{
      run_id: run.id,
      issue_number: number,
      issue_id: issue && issue.id,
      added_by: added_by
    })
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:run_id, :issue_number])
  end

  defp member?(repo, run, number),
    do: repo.exists?(from m in Member, where: m.run_id == ^run.id and m.issue_number == ^number)

  defp member_in_flight?(issue_id) do
    Repo.exists?(
      from job in Job,
        left_join: publication in assoc(job, :pr_publication),
        where:
          job.issue_id == ^issue_id and
            (job.state in ^@live_job_states or
               (publication.state == "published" and publication.pr_state == "open"))
    )
  end

  defp parent_run(_repo, %Issue{parent_issue_number: nil}), do: nil

  defp parent_run(repo, %Issue{} = issue) do
    repo.one(
      from run in Run,
        join: umbrella in Issue,
        on: umbrella.id == run.issue_id,
        where:
          umbrella.repository_id == ^issue.repository_id and
            umbrella.number == ^issue.parent_issue_number and run.state in ^Run.live_states(),
        limit: 1
    )
  end

  defp validate_structure(issue) do
    case Structure.validate(issue) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:structure_invalid, reason})
    end
  end

  ## Steps and actions

  defp step_exists?(run, kind, scope_or_prefix) do
    if String.ends_with?(scope_or_prefix, ":") do
      pattern = scope_or_prefix <> "%"

      Repo.exists?(
        from step in Step,
          where: step.run_id == ^run.id and step.kind == ^kind and like(step.scope, ^pattern)
      )
    else
      Repo.exists?(
        from step in Step,
          where: step.run_id == ^run.id and step.kind == ^kind and step.scope == ^scope_or_prefix
      )
    end
  end

  defp record_step!(run, kind, scope, actor, attrs) do
    %Step{}
    |> Step.changeset(Map.merge(attrs, %{run_id: run.id, kind: kind, scope: scope, actor: actor}))
    |> Repo.insert!()
  end

  defp overridden?(_run, nil), do: false
  defp overridden?(run, scope), do: step_exists?(run, "override", scope)

  # Where one bounded, action-backed effect stands: never tried, outstanding,
  # done, retryable after a failure, or exhausted.
  defp action_attempt(run, kind, prefix, max \\ @max_action_attempts) do
    pattern = prefix <> "%"

    steps =
      Repo.all(
        from step in Step,
          where: step.run_id == ^run.id and step.kind == ^kind and like(step.scope, ^pattern),
          order_by: [asc: step.id]
      )

    case List.last(steps) do
      nil ->
        {:retry, 1}

      %Step{agent_action_id: nil} ->
        {:done, nil}

      %Step{agent_action_id: action_id} ->
        case Repo.get(AgentAction, action_id) do
          nil ->
            {:retry, length(steps) + 1}

          %AgentAction{state: state} = action when state in @outstanding_states ->
            {:outstanding, action}

          %AgentAction{state: "done"} = action ->
            {:done, action}

          _failed when length(steps) < max ->
            {:retry, length(steps) + 1}

          action ->
            {:exhausted, action}
        end
    end
  end

  defp outstanding_actions(run) do
    Repo.all(
      from action in AgentAction,
        where:
          action.repository_id == ^run.repository_id and action.actor == ^@actor and
            action.state in ^@outstanding_states
    )
  end

  defp outstanding_umbrella_actions(run, umbrella) do
    Repo.all(
      from action in AgentAction,
        where:
          action.repository_id == ^run.repository_id and action.target_type == "issue" and
            action.target_id == ^umbrella.id and action.state in ^@outstanding_states
    )
  end

  defp cancel_queued_actions(run, actor) do
    steps =
      Repo.all(
        from step in Step,
          join: action in AgentAction,
          on: action.id == step.agent_action_id,
          where: step.run_id == ^run.id and action.state == "queued",
          select: {step, action}
      )

    for {step, action} <- steps do
      case Operations.cancel_queued_agent_action(action.id, actor) do
        {:ok, _cancelled} -> Repo.delete!(step)
        {:error, _no_longer_queued} -> :ok
      end
    end

    :ok
  end

  defp latest_merge_action(publication) do
    Repo.one(
      from action in AgentAction,
        where:
          action.action_key == "merge_reviewed_pr" and action.target_type == "pull_request" and
            action.target_id == ^publication.id,
        order_by: [desc: action.id],
        limit: 1
    )
  end

  defp unauthorized_merge(publication) do
    case latest_merge_action(publication) do
      %AgentAction{state: "failed", last_error: error} = action when is_binary(error) ->
        if String.contains?(error, "unexpected_merge_head"), do: action

      _action ->
        nil
    end
  end

  defp merge_action_failed?(nil, _publication), do: false

  defp merge_action_failed?(%AgentAction{} = action, publication) do
    same_head? =
      get_in(action.target_snapshot || %{}, ["authorized_head_sha"]) ==
        publication.remote_head_sha

    same_head? and
      (action.state == "failed" or
         (action.state == "done" and action_outcome(action) == "repair-blocked"))
  end

  defp action_outcome(%AgentAction{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"outcome" => outcome}} -> outcome
      _other -> nil
    end
  end

  defp action_outcome(_action), do: nil

  defp action_created_numbers(%AgentAction{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"created_issue_numbers" => numbers}} when is_list(numbers) -> numbers
      _other -> []
    end
  end

  defp action_created_numbers(_action), do: []

  defp latest_job(%Issue{id: issue_id}) do
    Job
    |> where([job], job.issue_id == ^issue_id)
    |> order_by([job], desc: job.id)
    |> limit(1)
    |> preload(:pr_publication)
    |> Repo.one()
  end

  defp merged_publications(%Issue{id: issue_id}) do
    Repo.all(
      from publication in PrPublication,
        join: job in assoc(publication, :job),
        where: job.issue_id == ^issue_id and publication.pr_state == "merged"
    )
  end

  defp linked_publication?(repo, issue),
    do: PtcManager.AutoImplementation.linked_publication?(repo, issue)

  ## Transitions

  defp transition(run_id, actor, fun) do
    with :ok <- OperationalMode.authorize_ordinary_work() do
      result =
        RepoTransaction.immediate(fn ->
          case Repo.get(Run, run_id) do
            nil -> Repo.rollback(:not_found)
            run -> fun.(run)
          end
        end)

      case result do
        {:ok, run} ->
          audit(run, "collection_run.#{run.state}", %{
            actor: actor,
            reason: run.pause_reason || run.end_reason
          })

          Operations.notify_changed(__MODULE__)
          {:ok, run}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp apply_transition(run, fun, audit_action, details) do
    case RepoTransaction.immediate(fn -> fun.(Repo.get!(Run, run.id)) end) do
      {:ok, updated} ->
        audit(updated, audit_action, details)
        Operations.notify_changed(__MODULE__)
        :ok

      {:error, reason} ->
        Logger.info("Collection run #{run.id}: #{audit_action} skipped: #{inspect(reason)}")
        :ok
    end
  end

  defp apply_end(run, state, reason) do
    apply_transition(
      run,
      fn current ->
        unless Run.live?(current), do: Repo.rollback(:run_not_live)
        cancel_queued_actions(current, @actor)
        end_run(current, state, reason)
      end,
      "collection_run.#{state}",
      %{reason: reason}
    )
  end

  defp end_run(run, state, reason) do
    run
    |> Run.changeset(%{
      state: state,
      end_reason: reason,
      ended_at: utc_now(),
      escalation_pending: false
    })
    |> Repo.update!()
  end

  defp activate(run) do
    run
    |> Run.changeset(%{
      state: "active",
      pause_kind: nil,
      pause_reason: nil,
      pause_scope: nil,
      paused_issue_number: nil,
      pause_reference_id: nil,
      paused_at: nil,
      escalation_pending: false
    })
    |> Repo.update!()
  end

  defp finish(run) do
    if run.state != "active", do: Repo.rollback(:run_not_active)
    run |> Run.changeset(%{state: "finishing"}) |> Repo.update!()
  end

  defp audit(run, action, details) do
    ExecutionProfiles.audit(@actor, action, run.id, details, "collection_run")
  end

  defp console_url(%Issue{} = umbrella) do
    umbrella = Repo.preload(umbrella, :repository)
    repository = umbrella.repository

    PtcManagerWeb.Endpoint.url() <>
      "/?repo=#{repository.github_owner}/#{repository.github_name}#issue-#{umbrella.id}"
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
