defmodule PtcManager.Stalls do
  @moduledoc """
  Conditions the console should have handled by itself, computed from the
  tables it already writes.

  A stall is a predicate over collection runs, jobs, agent actions, review
  rounds, resource operations, publications, agent runs, and audit events; it
  is never stored, so nothing can disagree with the records it reads. Every
  detector is a public function that takes the current time, so each can be
  tested against fixtures on its own, and `detect/1` runs all of them.

  `severity: :alarm` means a program should have resolved the condition and
  did not; `severity: :attention` means the condition waits for a person's
  decision. Each stall names a target the console has a page for, and
  `detail` says in words what is wrong and what answers it.
  """

  import Ecto.Query

  alias PtcManager.{Collections, OperationalMode, Repo, Reviews}
  alias PtcManager.Collections.{Member, Run}
  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AgentAction,
    AgentHealth,
    AuditEvent,
    Job,
    PrPublication,
    ResourceOperation
  }

  alias PtcManager.Reviews.Round

  @type t :: %{
          kind: atom(),
          severity: :alarm | :attention,
          target_type: String.t(),
          target_id: pos_integer(),
          repository_id: pos_integer() | nil,
          issue_id: pos_integer() | nil,
          since: DateTime.t() | nil,
          detail: String.t()
        }

  @flap_window_ms 60_000
  @flap_lookback_ms 600_000
  @flaps_for_alarm 2
  @reconcile_interval_ms 60_000
  @rejection_lookback_ms 86_400_000
  @recent_actions 500
  @terminal_rejections ["issue_closed"]
  @live_job_states ~w(queued starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open publish_blocked)
  @pending_action_states ~w(queued running sync_pending)
  @open_review_states ~w(running paused manual changes_requested resume_pending)

  @doc "Every stall the console can compute right now, alarms first, oldest first."
  @spec detect(DateTime.t()) :: [t()]
  def detect(now \\ DateTime.utc_now()) do
    [
      &run_flapping/1,
      &run_idle_complete/1,
      &run_no_progress/1,
      &stop_unacknowledged/1,
      &action_repeating_failure/1,
      &review_snoozing/1,
      &review_repeated_finding/1,
      &operation_slot_orphaned/1,
      &dispatch_rejected/1,
      &publication_stuck_green/1,
      &agent_out_of_contact/1
    ]
    |> Enum.flat_map(& &1.(now))
    |> Enum.sort_by(&{severity_rank(&1.severity), since_rank(&1.since)})
  end

  @doc "The kind of a stall in words, for a page heading."
  def label(:run_flapping), do: "Run pausing and resuming"
  def label(:run_idle_complete), do: "Run delivered but not closed out"
  def label(:run_no_progress), do: "Run without progress"
  def label(:stop_unacknowledged), do: "Agent stop waiting for an answer"
  def label(:action_repeating_failure), do: "Action failing the same way twice"
  def label(:review_snoozing), do: "Review waiting on the console's mode"
  def label(:review_repeated_finding), do: "Review repeating a finding"
  def label(:operation_slot_orphaned), do: "Expensive-operation slot held by a lost operation"
  def label(:dispatch_rejected), do: "Dispatch rejected and nothing retried"
  def label(:publication_stuck_green), do: "Green member pull request not merged"
  def label(:agent_out_of_contact), do: "Agent out of contact"
  def label(:agent_needs_attention), do: "Agent needs a person"

  @doc "Milliseconds an active run may go without a job, action, or step before it counts as stalled."
  def run_no_progress_ms,
    do: Application.get_env(:ptc_manager, :stall_run_no_progress_ms, 1_800_000)

  @doc "Milliseconds a slot-holding operation may go without a heartbeat or recovery before it counts as lost."
  def operation_recovery_ms,
    do: Application.get_env(:ptc_manager, :stall_operation_recovery_ms, 300_000)

  @doc """
  A live run that paused and resumed within a minute, twice in the last ten
  minutes. The run looks healthy on its card while doing nothing; the pair is
  an alarm, not a state.
  """
  def run_flapping(now) do
    lookback = DateTime.add(now, -@flap_lookback_ms, :millisecond)

    events =
      Repo.all(
        from event in AuditEvent,
          where:
            event.target_type == "collection_run" and
              event.action in ["collection_run.paused", "collection_run.resumed"] and
              event.inserted_at >= ^lookback,
          order_by: [asc: event.target_id, asc: event.inserted_at, asc: event.id],
          select: {event.target_id, event.action, event.inserted_at}
      )

    runs = live_runs_by_id()

    events
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {run_id, run_events} ->
      flaps =
        run_events
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.filter(fn [{_, first_action, first_at}, {_, second_action, second_at}] ->
          first_action != second_action and
            DateTime.diff(second_at, first_at, :millisecond) <= @flap_window_ms
        end)

      case {Map.fetch(runs, run_id), flaps} do
        {{:ok, run}, [[{_, _, since} | _] | _]} when length(flaps) >= @flaps_for_alarm ->
          [
            stall(
              :run_flapping,
              :alarm,
              run,
              since,
              "The run for ##{run.issue.number} paused and resumed #{length(flaps)} times " <>
                "within a minute of each other in the last ten minutes. Something answers " <>
                "its own pause; stop reconciling it until the cause is known."
            )
          ]

        _other ->
          []
      end
    end)
  end

  @doc """
  An active run whose every member is closed as completed and whose last step
  is older than one reconcile, so nothing is queuing the close-out.
  """
  def run_idle_complete(now) do
    for run <- active_runs(),
        statuses = Collections.member_statuses(run),
        statuses != [],
        Enum.all?(statuses, &(&1.status == :closed_completed)),
        last = last_activity(run),
        elapsed_ms(last, now) > @reconcile_interval_ms do
      stall(
        :run_idle_complete,
        :alarm,
        run,
        last,
        "Every member of the run for ##{run.issue.number} is delivered, but no step has " <>
          "run for #{humanize(elapsed_ms(last, now))}. Queue the close-out or resume the run."
      )
    end
  end

  @doc """
  An active run with no live job, no pending action, and no step for longer
  than `run_no_progress_ms/0`, excluding runs already delivered in full.
  """
  def run_no_progress(now) do
    for run <- active_runs(),
        last = last_activity(run),
        elapsed_ms(last, now) > run_no_progress_ms(),
        statuses = Collections.member_statuses(run),
        not (statuses != [] and Enum.all?(statuses, &(&1.status == :closed_completed))),
        issue_ids = member_issue_ids(run),
        not live_job?(issue_ids),
        not pending_action?(issue_ids) do
      stall(
        :run_no_progress,
        :attention,
        run,
        last,
        "The run for ##{run.issue.number} has had no job, action, or step for " <>
          "#{humanize(elapsed_ms(last, now))}. Its members are " <>
          "#{describe_statuses(statuses)}; see why nothing admits the next one."
      )
    end
  end

  @doc "A job whose agent stopped with a report the maintainer has not answered."
  def stop_unacknowledged(_now) do
    for job <- Operations.unacknowledged_stopped_jobs() do
      report = job.stop_report || %{}

      %{
        kind: :stop_unacknowledged,
        severity: :attention,
        target_type: "job",
        target_id: job.id,
        repository_id: job.repository_id,
        issue_id: job.issue_id,
        since: job.stop_reported_at,
        detail:
          "The agent for ##{job.issue.number} stopped: #{reason_words(report["reason_code"])}" <>
            "#{summary_sentence(report["summary"])} Acknowledge or retry it on the delivery board."
      }
    end
  end

  @doc """
  The two most recent actions with the same key on the same target both
  failed with the same error. A retry that repeats the error needs a person,
  not a third attempt.
  """
  def action_repeating_failure(_now) do
    Repo.all(
      from action in AgentAction,
        order_by: [desc: action.id],
        limit: @recent_actions,
        preload: [:repository]
    )
    |> Enum.group_by(&{&1.action_key, &1.target_type, &1.target_id})
    |> Enum.flat_map(fn {_key, actions} ->
      case actions do
        [
          %AgentAction{state: "failed", last_error: error} = latest,
          %AgentAction{state: "failed", last_error: error} = previous | _
        ]
        when is_binary(error) ->
          [
            %{
              kind: :action_repeating_failure,
              severity: :alarm,
              target_type: "agent_action",
              target_id: latest.id,
              repository_id: latest.repository_id,
              issue_id: if(latest.target_type == "issue", do: latest.target_id),
              since: previous.ended_at || previous.updated_at,
              detail:
                "#{latest.action_key} on #{latest.target_label || "#{latest.target_type} #{latest.target_id}"} " <>
                  "failed twice in a row with the same error: #{truncate(error)}"
            }
          ]

        _other ->
          []
      end
    end)
  end

  @doc """
  A review round that cannot run because of the console's operational mode:
  the prepare and review workers snooze unless reconciliation is allowed, and
  the resume worker snoozes unless the mode is active.
  """
  def review_snoozing(_now) do
    mode = OperationalMode.mode()

    rounds =
      if OperationalMode.reconciliation_allowed?() do
        []
      else
        for round <-
              Repo.all(
                from round in Round,
                  where: round.state in ["queued", "preparing"],
                  preload: [job: [:issue]]
              ) do
          %{
            kind: :review_snoozing,
            severity: :alarm,
            target_type: "job",
            target_id: round.job_id,
            repository_id: round.job.repository_id,
            issue_id: round.job.issue_id,
            since: round.updated_at,
            detail:
              "Review round #{round.number} for ##{round.job.issue.number} is #{round.state}, " <>
                "but the console is in #{mode_words(mode)}, so review workers snooze. " <>
                "Activate the console or finish the deployment."
          }
        end
      end

    continuations =
      if OperationalMode.active?() do
        []
      else
        for job <-
              Repo.all(
                from job in Job,
                  where:
                    job.review_state == "resume_pending" and job.state in ^Reviews.active_states(),
                  preload: [:issue]
              ) do
          %{
            kind: :review_snoozing,
            severity: :alarm,
            target_type: "job",
            target_id: job.id,
            repository_id: job.repository_id,
            issue_id: job.issue_id,
            since: job.updated_at,
            detail:
              "The review continuation for ##{job.issue.number} is pending, but the console " <>
                "is in #{mode_words(mode)}, so the resume worker snoozes. Activate the console."
          }
        end
      end

    rounds ++ continuations
  end

  @doc """
  The last two completed rounds of a job with an open review share a finding.
  A finding that repeats means the agent is not fixing it; the round budget
  should stop being spent.
  """
  def review_repeated_finding(_now) do
    jobs =
      Repo.all(
        from job in Job,
          where:
            job.review_state in @open_review_states and job.state in ^Reviews.active_states(),
          preload: [:issue]
      )

    for job <- jobs,
        [latest, previous] <- [last_completed_rounds(job.id)],
        repeated = repeated_findings(latest, previous),
        repeated != [] do
      %{
        kind: :review_repeated_finding,
        severity: :attention,
        target_type: "job",
        target_id: job.id,
        repository_id: job.repository_id,
        issue_id: job.issue_id,
        since: latest.updated_at,
        detail:
          "Review round #{latest.number} for ##{job.issue.number} repeats a finding from " <>
            "round #{previous.number}: #{truncate(hd(repeated))} Decide on the review " <>
            "instead of spending another round."
      }
    end
  end

  @doc """
  An operation that holds an expensive-operation slot and has had neither a
  heartbeat nor a completed recovery for `operation_recovery_ms/0`. The
  broker marks a silent operation for recovery after seconds; this alarms
  when that recovery itself never runs.
  """
  def operation_slot_orphaned(now) do
    threshold = operation_recovery_ms()

    for operation <-
          Repo.all(
            from operation in ResourceOperation,
              where:
                not is_nil(operation.slot_number) and
                  operation.state in ["starting", "running", "cancelling", "recovery_pending"]
          ),
        since = operation_silent_since(operation),
        elapsed_ms(since, now) > threshold do
      %{
        kind: :operation_slot_orphaned,
        severity: :alarm,
        target_type: "resource_operation",
        target_id: operation.id,
        repository_id: operation.repository_id,
        issue_id: nil,
        since: since,
        detail:
          "Operation #{operation.id} (#{operation.label || "unlabelled"}) holds slot " <>
            "#{operation.slot_number} in state #{operation.state} with " <>
            "#{if operation.wrapper_pid, do: "no heartbeat", else: "no wrapper process"} for " <>
            "#{humanize(elapsed_ms(since, now))}, and recovery has not released it."
      }
    end
  end

  @doc """
  A job that dispatch cancelled for a reason that is not terminal, with no
  newer job for the same issue. A person has to retry it by hand today.
  """
  def dispatch_rejected(now) do
    lookback = DateTime.add(now, -@rejection_lookback_ms, :millisecond)

    events =
      Repo.all(
        from event in AuditEvent,
          where: event.action == "job.dispatch_rejected" and event.inserted_at >= ^lookback,
          order_by: [asc: event.inserted_at, asc: event.id]
      )

    jobs =
      events
      |> Enum.map(& &1.target_id)
      |> then(&Repo.all(from job in Job, where: job.id in ^&1, preload: [:issue]))
      |> Map.new(&{&1.id, &1})

    for event <- events,
        reason = event.details["reason"] || "unknown",
        reason not in @terminal_rejections,
        {:ok, %Job{state: "cancelled"} = job} <- [Map.fetch(jobs, event.target_id)],
        not newer_job?(job) do
      %{
        kind: :dispatch_rejected,
        severity: :attention,
        target_type: "job",
        target_id: job.id,
        repository_id: job.repository_id,
        issue_id: job.issue_id,
        since: event.inserted_at,
        detail:
          "Dispatch rejected the job for ##{job.issue.number} (#{reason}) and nothing has " <>
            "retried it. Approve the issue again once the cause is gone."
      }
    end
  end

  @doc """
  A published member pull request of an active run with automatic merging that
  is green, mergeable, at its reviewed head, and has no merge action after two
  reconciles. Outside a run a green pull request is the maintainer's decision.
  """
  def publication_stuck_green(now) do
    checked_before = DateTime.add(now, -2 * @reconcile_interval_ms, :millisecond)

    candidates =
      Repo.all(
        from publication in PrPublication,
          join: job in Job,
          on: job.id == publication.job_id,
          join: member in Member,
          on: member.issue_id == job.issue_id,
          join: run in Run,
          on: run.id == member.run_id,
          where:
            run.state == "active" and run.auto_merge and publication.state == "published" and
              publication.pr_state == "open" and publication.mergeability == "mergeable" and
              publication.checks_state in ["success", "none"] and
              publication.head_sha == publication.remote_head_sha and
              publication.pr_checked_at <= ^checked_before,
          preload: [job: [:issue]]
      )

    for publication <- candidates,
        Reviews.publication_allowed?(publication.job, publication),
        not merge_action_pending?(publication) do
      %{
        kind: :publication_stuck_green,
        severity: :alarm,
        target_type: "pr_publication",
        target_id: publication.id,
        repository_id: publication.job.repository_id,
        issue_id: publication.job.issue_id,
        since: publication.pr_checked_at,
        detail:
          "Pull request ##{publication.pr_number} for ##{publication.job.issue.number} has been " <>
            "green and mergeable at its reviewed head since " <>
            "#{humanize(elapsed_ms(publication.pr_checked_at, now))} ago, and its run has not " <>
            "queued a merge. Check the run's last refused effect."
      }
    end
  end

  @doc "Live agent runs that `AgentHealth` says a person has to look at."
  def agent_out_of_contact(now) do
    for run <- AgentHealth.needing_attention(Operations.list_active_agent_runs(), now) do
      assessment = AgentHealth.assess(run, now)

      %{
        kind:
          if(assessment.label == "Out of contact",
            do: :agent_out_of_contact,
            else: :agent_needs_attention
          ),
        severity: :attention,
        target_type: "agent_run",
        target_id: run.id,
        repository_id: agent_run_repository_id(run),
        issue_id: run.job && run.job.issue_id,
        since: run.state_changed_at || run.last_heartbeat_at || run.started_at,
        detail: "#{agent_run_words(run)}: #{assessment.detail}"
      }
    end
  end

  ## Runs

  defp active_runs do
    Repo.all(
      from run in Run,
        where: run.state == "active",
        preload: [:issue, :steps, :members]
    )
  end

  defp live_runs_by_id do
    Repo.all(from run in Run, where: run.state in ^Run.live_states(), preload: [:issue])
    |> Map.new(&{&1.id, &1})
  end

  defp last_activity(%Run{} = run) do
    run.steps
    |> Enum.map(& &1.inserted_at)
    |> Enum.concat([run.started_at, run.updated_at])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> run.inserted_at end)
  end

  defp member_issue_ids(%Run{members: members}),
    do: members |> Enum.map(& &1.issue_id) |> Enum.reject(&is_nil/1)

  defp live_job?([]), do: false

  defp live_job?(issue_ids) do
    Repo.exists?(
      from job in Job,
        where: job.issue_id in ^issue_ids and job.state in @live_job_states
    )
  end

  defp pending_action?([]), do: false

  defp pending_action?(issue_ids) do
    publication_ids =
      Repo.all(
        from publication in PrPublication,
          join: job in Job,
          on: job.id == publication.job_id,
          where: job.issue_id in ^issue_ids,
          select: publication.id
      )

    Repo.exists?(
      from action in AgentAction,
        where:
          action.state in @pending_action_states and
            ((action.target_type == "issue" and action.target_id in ^issue_ids) or
               (action.target_type == "pull_request" and action.target_id in ^publication_ids))
    )
  end

  defp describe_statuses(statuses) do
    statuses
    |> Enum.frequencies_by(& &1.status)
    |> Enum.map_join(", ", fn {status, count} -> "#{count} #{status_words(status)}" end)
  end

  defp status_words(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp stall(kind, severity, %Run{} = run, since, detail) do
    %{
      kind: kind,
      severity: severity,
      target_type: "collection_run",
      target_id: run.id,
      repository_id: run.repository_id,
      issue_id: run.issue_id,
      since: since,
      detail: detail
    }
  end

  ## Reviews

  defp last_completed_rounds(job_id) do
    Repo.all(
      from round in Round,
        where: round.job_id == ^job_id and round.state == "completed",
        order_by: [desc: round.number, desc: round.id],
        limit: 2
    )
  end

  defp repeated_findings(%Round{} = latest, %Round{} = previous) do
    previous_findings = findings(previous) |> Enum.map(&normalize/1) |> MapSet.new()

    latest
    |> findings()
    |> Enum.filter(&MapSet.member?(previous_findings, normalize(&1)))
  end

  defp findings(%Round{result: %{"findings" => findings}}) when is_list(findings) do
    for %{"description" => description} when is_binary(description) <- findings,
        do: description
  end

  defp findings(_round), do: []

  defp normalize(text), do: text |> String.downcase() |> String.split() |> Enum.join(" ")

  ## Operations

  defp operation_silent_since(%ResourceOperation{state: "recovery_pending"} = operation),
    do: operation.updated_at

  defp operation_silent_since(operation),
    do: operation.last_heartbeat_at || operation.started_at || operation.queued_at

  defp newer_job?(%Job{} = job) do
    Repo.exists?(from other in Job, where: other.issue_id == ^job.issue_id and other.id > ^job.id)
  end

  defp merge_action_pending?(%PrPublication{id: id}) do
    Repo.exists?(
      from action in AgentAction,
        where:
          action.action_key == "merge_reviewed_pr" and action.target_type == "pull_request" and
            action.target_id == ^id and
            action.state in ["queued", "running", "sync_pending", "done"]
    )
  end

  defp agent_run_repository_id(%{job: %{repository_id: id}}) when is_integer(id), do: id
  defp agent_run_repository_id(%{agent_action: %{repository_id: id}}) when is_integer(id), do: id
  defp agent_run_repository_id(_run), do: nil

  defp agent_run_words(%{job: %{issue: %{number: number}}}), do: "The agent for ##{number}"

  defp agent_run_words(%{agent_action: %{action_key: key}}) when is_binary(key),
    do: "The #{key} agent"

  defp agent_run_words(%{agent_name: name}) when is_binary(name), do: "Agent #{name}"
  defp agent_run_words(_run), do: "An agent"

  ## Words

  defp reason_words("missing_prerequisite"), do: "a prerequisite is missing"
  defp reason_words("environment_broken"), do: "the environment is broken"
  defp reason_words("ambiguous_requirement"), do: "the requirement is ambiguous"
  defp reason_words("unsafe_to_proceed"), do: "it was unsafe to proceed"
  defp reason_words(other) when is_binary(other), do: other
  defp reason_words(_reason), do: "no reason was recorded"

  defp summary_sentence(summary) when is_binary(summary) and summary != "",
    do: " (#{truncate(summary)})."

  defp summary_sentence(_summary), do: "."

  defp mode_words(:maintenance), do: "maintenance mode"
  defp mode_words(:draining), do: "a deployment drain"
  defp mode_words({:canary, _id}), do: "a canary"
  defp mode_words(mode), do: "#{inspect(mode)} mode"

  defp truncate(text) when is_binary(text) do
    text = text |> String.split() |> Enum.join(" ")
    if String.length(text) > 160, do: String.slice(text, 0, 157) <> "...", else: text
  end

  defp humanize(milliseconds), do: AgentHealth.humanize(milliseconds)

  defp elapsed_ms(nil, _now), do: 0
  defp elapsed_ms(%DateTime{} = at, now), do: now |> DateTime.diff(at, :millisecond) |> max(0)

  defp severity_rank(:alarm), do: 0
  defp severity_rank(:attention), do: 1

  defp since_rank(nil), do: 0
  defp since_rank(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
end
