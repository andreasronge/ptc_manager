defmodule PtcManager.Reviews do
  @moduledoc "Durable review admission and exact-commit approval, independent of agent claims."
  import Ecto.Query
  alias PtcManager.{Repo, RepoTransaction, ExecutionProfiles}
  alias PtcManager.Operations.Job
  alias PtcManager.Reviews.Round

  @active ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result)
  def active_job?(%{state: state}), do: state in @active

  def rounds(id), do: Repo.all(from r in Round, where: r.job_id == ^id, order_by: r.number)

  def timeout_ms(job), do: (job.execution_settings || %{})["review_timeout_ms"] || 900_000

  defp completed_count(id),
    do:
      Repo.aggregate(from(r in Round, where: r.job_id == ^id and r.state == "completed"), :count)

  def held?(%{review_state: state}),
    do: state in ~w(paused manual cancelled resume_pending running)

  def held?(_), do: false

  def publication_allowed?(%{execution_settings: settings} = job, %{
        head_sha: head,
        base_sha: base,
        diff_digest: digest
      })
      when is_map(settings) do
    if job.required_review_count == 0 and job.review_state == "skipped" do
      true
    else
      job.review_state == "passed" and job.reviewed_head_sha == head and
        Repo.exists?(
          from r in Round,
            where:
              r.job_id == ^job.id and r.fencing_token == ^job.fencing_token and
                r.generation == ^job.review_generation and r.state == "completed" and
                r.head_sha == ^head and
                r.base_sha == ^base and r.diff_digest == ^digest
        )
    end
  end

  def publication_allowed?(%{execution_settings: nil}, _head), do: true
  def publication_allowed?(_, _), do: false

  def request(job_id, fence, request_id, opts \\ []) do
    with true <- is_binary(request_id) and byte_size(request_id) in 1..80,
         {:ok, admitted} <- admit(job_id, fence, request_id) do
      finish_admission(admitted, Keyword.get(opts, :snapshot, PtcManager.Reviews.Snapshot))
    else
      false -> {:error, :review_not_admissible}
      error -> error
    end
  end

  defp finish_admission({:prepare, round, job}, snapshot), do: prepare(round, job, snapshot)
  defp finish_admission(result, _snapshot), do: {:ok, result}

  defp admit(job_id, fence, request_id) do
    RepoTransaction.immediate(fn -> admit_locked(job_id, fence, request_id) end)
  end

  defp admit_locked(job_id, fence, request_id) do
    job = Repo.get!(Job, job_id)

    unless is_map(job.execution_settings) and job.fencing_token == fence and
             job.state in @active,
           do: Repo.rollback(:review_not_admissible)

    existing = Repo.get_by(Round, job_id: job_id, request_id: request_id)

    running =
      Repo.one(
        from r in Round, where: r.job_id == ^job_id and r.state in ~w(preparing queued running)
      )

    cond do
      existing && existing.generation == job.review_generation &&
          existing.fencing_token == fence ->
        existing

      existing ->
        Repo.rollback(:stale_review)

      job.review_state == "paused" ->
        :paused

      running ->
        running

      held?(job) ->
        Repo.rollback(:review_not_admissible)

      job.required_review_count == 0 ->
        :skipped

      true ->
        round =
          %Round{}
          |> Round.changeset(%{
            job_id: job_id,
            fencing_token: fence,
            generation: job.review_generation,
            number: Repo.aggregate(from(r in Round, where: r.job_id == ^job_id), :count) + 1,
            request_id: request_id,
            state: "preparing",
            input: %{
              "settings" => job.execution_settings,
              "contract_version" => 2,
              "schema" => review_schema()
            },
            expires_at: DateTime.add(DateTime.utc_now(), timeout_ms(job) + 900_000, :millisecond)
          })
          |> Repo.insert!()

        update_job(job, %{review_state: "running", review_resume_expires_at: nil})

        %{round_id: round.id}
        |> PtcManager.Reviews.PrepareWorker.new(schedule_in: 5)
        |> Oban.insert!()

        {:prepare, round, Repo.preload(job, [:repository, :issue, :worktree_allocation])}
    end
  end

  defp review_schema do
    Application.app_dir(:ptc_manager, "priv/codex/independent_review.schema.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp prepare(round, job, snapshot) do
    result =
      try do
        snapshot.capture(job)
      rescue
        error -> {:error, {:snapshot_exception, Exception.message(error)}}
      end

    case result do
      {:ok, input} ->
        case finish_preparation(round, input) do
          {:error, :database_busy} -> {:ok, round}
          {:error, :stale_review} -> replay_preparation(round)
          result -> result
        end

      {:error, reason} ->
        case fail_round(round.id, {:preparation, reason}, ["preparing"]) do
          {:ok, _} -> replay_preparation(round)
          {:error, :database_busy} -> {:ok, round}
          error -> error
        end
    end
  end

  def prepare_pending(id, opts \\ []) do
    with {:ok, {round, job}} <-
           RepoTransaction.immediate(fn ->
             round = Repo.get(Round, id) || Repo.rollback(:stale_review)

             job =
               Repo.get!(Job, round.job_id)
               |> Repo.preload([:repository, :issue, :worktree_allocation])

             unless preparation_current?(round, job), do: Repo.rollback(:stale_review)
             {round, job}
           end) do
      prepare(round, job, Keyword.get(opts, :snapshot, PtcManager.Reviews.Snapshot))
    end
  end

  defp preparation_current?(round, job) do
    round.state == "preparing" and job.review_state == "running" and
      job.review_generation == round.generation and job.fencing_token == round.fencing_token and
      active_job?(job) and DateTime.compare(round.expires_at, DateTime.utc_now()) == :gt
  end

  defp replay_preparation(round) do
    current = Repo.get!(Round, round.id)
    job = Repo.get!(Job, round.job_id)

    if current.state != "preparing" and job.review_generation == round.generation and
         job.fencing_token == round.fencing_token and active_job?(job),
       do: {:ok, current},
       else: {:error, :stale_review}
  end

  defp finish_preparation(round, input) do
    RepoTransaction.immediate(fn ->
      current = Repo.get!(Round, round.id)
      job = Repo.get!(Job, round.job_id)

      unless preparation_current?(current, job), do: Repo.rollback(:stale_review)

      cached =
        Repo.one(
          from r in Round,
            where:
              r.job_id == ^job.id and r.generation == ^job.review_generation and
                r.fencing_token == ^job.fencing_token and r.state == "completed" and
                r.head_sha == ^input["head_sha"] and
                r.base_sha == ^input["base_sha"] and r.diff_digest == ^input["diff_digest"],
            order_by: [desc: r.number],
            limit: 1
        )

      attrs = %{
        head_sha: input["head_sha"],
        base_sha: input["base_sha"],
        diff_digest: input["diff_digest"],
        input: Map.merge(current.input, input)
      }

      cond do
        cached ->
          state = if cached.result["findings"] == [], do: "passed", else: "changes_requested"

          update_job(job, %{
            review_state: state,
            reviewed_head_sha: if(state == "passed", do: cached.head_sha)
          })

          current
          |> Round.changeset(Map.merge(attrs, %{state: "cached", result: cached.result}))
          |> Repo.update!()

        completed_count(job.id) >= job.required_review_count ->
          update_job(job, %{
            review_state: "paused",
            last_error:
              "The current commit needs review; the completed review budget is exhausted."
          })

          current
          |> Round.changeset(
            Map.merge(attrs, %{
              state: "not_run",
              error: "Review budget exhausted; work preserved."
            })
          )
          |> Repo.update!()

          :paused

        true ->
          saved = current |> Round.changeset(Map.put(attrs, :state, "queued")) |> Repo.update!()
          update_job(job, %{reviewed_head_sha: nil, last_error: nil})
          %{round_id: saved.id} |> PtcManager.Reviews.Worker.new() |> Oban.insert!()

          ExecutionProfiles.audit("coordinator", "review.requested", job.id, %{
            round: saved.number,
            head_sha: saved.head_sha
          })

          saved
      end
    end)
    |> notify()
  end

  def claim(id) do
    RepoTransaction.immediate(fn ->
      round = Repo.get!(Round, id)
      job = Repo.get!(Job, round.job_id)

      unless round.state == "queued" and job.state in @active and job.review_state == "running" and
               job.fencing_token == round.fencing_token and
               job.review_generation == round.generation and
               DateTime.compare(round.expires_at, DateTime.utc_now()) == :gt,
             do: Repo.rollback(:stale_review)

      round |> Round.changeset(%{state: "running"}) |> Repo.update!()
    end)
  end

  def pause(id, reason, expected) do
    RepoTransaction.immediate(fn ->
      job = Repo.get!(Job, id)

      if (job.execution_settings && job.state in @active) and
           job.fencing_token == expected.fencing_token and
           job.review_generation == expected.review_generation and
           job.review_state == expected.review_state do
        update_job(job, %{
          state:
            if(expected.review_state in ~w(resume_pending changes_requested),
              do: "reconciling",
              else: job.state
            ),
          review_state: "paused",
          last_error: to_string(reason),
          lease_expires_at: nil,
          review_resume_expires_at: nil
        })
      end
    end)
    |> notify()
  end

  def sweep do
    now = DateTime.utc_now()

    Repo.all(
      from r in Round,
        where: r.state in ["preparing", "queued", "running"] and r.expires_at < ^now
    )
    |> Enum.each(&fail(&1.id, :review_expired))

    Repo.all(
      from j in Job,
        where:
          j.review_state in ["resume_pending", "changes_requested"] and
            not is_nil(j.review_resume_expires_at) and j.review_resume_expires_at < ^now
    )
    |> Enum.each(
      &pause(
        &1.id,
        "Continuation interrupted; work preserved. Inspect the retained agent before retrying.",
        &1
      )
    )

    Repo.all(
      from j in Job,
        where: not is_nil(j.review_recovery_expires_at) and j.review_recovery_expires_at < ^now
    )
    |> Enum.each(fn job ->
      RepoTransaction.immediate(fn ->
        current = Repo.get!(Job, job.id)

        if current.review_generation == job.review_generation and
             current.review_recovery_expires_at == job.review_recovery_expires_at do
          update_job(current, %{
            review_recovery_expires_at: nil,
            review_state:
              if(current.review_state in ~w(manual cancelled),
                do: current.review_state,
                else: "paused"
              ),
            state: if(active_job?(current), do: "reconciling", else: current.state),
            last_error:
              "Retained-agent recovery was interrupted; work is preserved. Continue to check its identity again."
          })
        end
      end)
    end)

    PtcManager.Reviews.Snapshots.sweep()
    :ok
  end

  def complete(id, result) do
    RepoTransaction.immediate(fn ->
      round = Repo.get!(Round, id)
      job = Repo.get!(Job, round.job_id)

      unless round.state in ~w(queued running) and job.fencing_token == round.fencing_token and
               job.review_generation == round.generation and job.review_state == "running" and
               job.state in @active and
               DateTime.compare(round.expires_at, DateTime.utc_now()) == :gt,
             do: Repo.rollback(:stale_review)

      unless valid_result?(result), do: Repo.rollback(:invalid_review_result)

      state =
        cond do
          result["findings"] == [] -> "passed"
          completed_count(job.id) + 1 >= job.required_review_count -> "paused"
          true -> "changes_requested"
        end

      round |> Round.changeset(%{state: "completed", result: result}) |> Repo.update!()

      retry_only = job.review_resume_mode == "assessment"

      next_state =
        if retry_only,
          do: if(state == "passed", do: "resume_pending", else: "paused"),
          else: state

      update_job(job, %{
        review_state: next_state,
        review_resume_mode:
          if(retry_only and state == "passed", do: "publication", else: job.review_resume_mode),
        reviewed_head_sha: if(state == "passed", do: round.head_sha)
      })

      if retry_only and state == "passed" do
        %{job_id: job.id, generation: job.review_generation}
        |> PtcManager.Reviews.ResumeWorker.new()
        |> Oban.insert!()
      end

      ExecutionProfiles.audit("coordinator", "review.completed", job.id, %{
        round: round.number,
        head_sha: round.head_sha,
        state: state
      })

      round
    end)
    |> notify()
  end

  def fail(id, reason), do: fail_round(id, reason, ~w(preparing queued running))

  defp fail_round(id, reason, allowed_states) do
    RepoTransaction.immediate(fn ->
      round = Repo.get!(Round, id)

      if round.state in allowed_states do
        round
        |> Round.changeset(%{
          state: "failed",
          error: failure_message(reason),
          failure: failure_details(reason)
        })
        |> Repo.update!()

        job = Repo.get!(Job, round.job_id)

        if job.fencing_token == round.fencing_token and job.review_generation == round.generation and
             job.state in @active,
           do: update_job(job, %{review_state: "paused"})
      end

      :ok
    end)
    |> notify()
  end

  defp failure_details({:preparation, reason}),
    do: %{"stage" => "preparation", "code" => failure_message(reason)}

  defp failure_details({:reviewer_command_failed, status, _}),
    do: %{"stage" => "reviewer", "code" => "reviewer_command_failed", "exit_status" => status}

  defp failure_details(reason), do: %{"stage" => "reviewer", "code" => failure_message(reason)}

  def failure_message({:reviewer_command_failed, status, output}) do
    "Reviewer exited with status #{status}.\n" <> String.slice(String.trim(output), -2_200, 2_200)
  end

  def failure_message(reason),
    do: inspect(reason, limit: 20, printable_limit: 2_000) |> String.slice(0, 2_400)

  def status(job_id, id) do
    case Repo.get_by(Round, id: id, job_id: job_id) do
      nil ->
        {:error, :review_missing}

      round ->
        if round.state in ~w(preparing queued running) and
             DateTime.compare(round.expires_at, DateTime.utc_now()) != :gt do
          fail(id, :review_expired)
          {:ok, Repo.get!(Round, id)}
        else
          {:ok, round}
        end
    end
  end

  def decision_available?(job) do
    (job.review_state in ~w(paused manual resume_pending) and job.state in @active) or
      stopped_work_available?(job) or
      publication_repair_available?(job)
  end

  defp stopped_work_available?(
         %Job{state: "failed", stop_acknowledged_at: nil, execution_settings: settings} = job
       )
       when is_map(settings) do
    report = job.stop_report || %{}

    not is_nil(job.stop_reported_at) and report["progress"] == "partial" and
      PtcManager.Operations.StopReport.allows?(report, :retry) and
      not Repo.exists?(
        from newer in Job, where: newer.issue_id == ^job.issue_id and newer.id > ^job.id
      )
  end

  defp stopped_work_available?(_), do: false

  defp publication_repair_available?(
         %Job{
           state: "publish_blocked",
           pre_publication_status: "failed",
           execution_settings: settings
         } = job
       )
       when is_map(settings) do
    Repo.exists?(
      from p in PtcManager.Operations.PrPublication,
        where:
          p.job_id == ^job.id and p.source == "broker" and p.state == "blocked" and
            is_nil(p.pr_number)
    )
  end

  defp publication_repair_available?(_), do: false

  def retry_available?(job),
    do:
      job.review_state in ~w(paused manual) and job.state in @active and
        match?(%{state: "failed"}, List.last(rounds(job.id)))

  def start_retry(job) do
    with {:ok, admitted} <-
           RepoTransaction.immediate(fn ->
             current = Repo.get!(Job, job.id)

             unless active_job?(current) and current.review_state == "resume_pending" and
                      current.review_generation == job.review_generation and
                      current.review_resume_mode == "assessment",
                    do: Repo.rollback(:stale_continuation)

             update_job(current, %{review_state: "pending", last_error: nil})
             admit_locked(current.id, current.fencing_token, "retry-#{current.review_generation}")
           end) do
      finish_admission(admitted, PtcManager.Reviews.Snapshot)
    end
  end

  def decide(id, generation, action, attrs, actor) do
    RepoTransaction.immediate(fn ->
      job = Repo.get!(Job, id)

      unless decision_available?(job) and job.review_generation == generation and
               is_nil(job.review_recovery_expires_at),
             do: Repo.rollback(:review_decision_stale)

      if action in ["continue", "retry_review"] do
        if job.review_state == "resume_pending", do: Repo.rollback(:review_decision_stale)

        if action == "retry_review" and not retry_available?(job),
          do: Repo.rollback(:review_retry_unavailable)

        instructions =
          case attrs["instructions"] do
            nil ->
              nil

            value when is_binary(value) ->
              value = String.trim(value)

              if String.length(value) > 4_000,
                do: Repo.rollback(:invalid_continuation_instructions)

              if value == "", do: nil, else: value

            _ ->
              Repo.rollback(:invalid_continuation_instructions)
          end

        extra = attrs["extra_rounds"] || 0

        unless is_integer(extra) and extra in 0..5 and job.required_review_count + extra <= 100,
          do: Repo.rollback(:invalid_review_budget)

        settings =
          case attrs["profile"] do
            name when name in ~w(small standard strong) ->
              case ExecutionProfiles.freeze(nil, name, nil) do
                {:ok, settings, _} -> Map.merge(job.execution_settings, settings)
                {:error, reason} -> Repo.rollback(reason)
              end

            _ ->
              job.execution_settings
          end

        count = completed_count(id)

        unless job.required_review_count + extra > count,
          do: Repo.rollback(:review_budget_exhausted)

        saved =
          update_job(job, %{
            required_review_count: job.required_review_count + extra,
            execution_settings: settings,
            review_continuation_instructions: instructions,
            review_resume_mode:
              if(action == "retry_review", do: "assessment", else: "implementation"),
            state: if(job.state in ["failed", "publish_blocked"], do: "blocked", else: job.state),
            stop_acknowledged_at:
              if(job.stop_reported_at, do: DateTime.utc_now(), else: job.stop_acknowledged_at),
            stop_report_token: PtcManager.Operations.StopReport.new_token(),
            review_state: "resume_pending",
            reviewed_head_sha: nil,
            review_generation: generation + 1,
            review_resume_expires_at: nil
          })

        %{job_id: id, generation: saved.review_generation}
        |> PtcManager.Reviews.ResumeWorker.new()
        |> Oban.insert!()

        ExecutionProfiles.audit(actor, "review.continued", id, %{
          extra_rounds: extra,
          instructions: instructions,
          settings: settings
        })

        saved
      else
        unless action in ~w(manual cancel), do: Repo.rollback(:invalid_review_decision)
        reason = String.trim(attrs["reason"] || "")

        if action == "cancel" and (reason == "" or String.length(reason) > 2000),
          do: Repo.rollback(:reason_required)

        changes = %{
          review_state: if(action == "manual", do: "manual", else: "cancelled"),
          review_generation: generation + 1,
          lease_expires_at: nil
        }

        changes =
          if action == "cancel",
            do:
              Map.merge(changes, %{
                state: "cancelled",
                cancellation_reason: reason,
                ended_at: DateTime.utc_now()
              }),
            else: changes

        saved = update_job(job, changes)

        if action == "cancel" do
          case Repo.get_by(PtcManager.Operations.WorktreeAllocation, job_id: id) do
            nil ->
              :ok

            allocation ->
              PtcManager.Operations.mark_worktree_attention(allocation.id, reason, actor)
          end
        end

        %{job_id: id, generation: saved.review_generation}
        |> PtcManager.Reviews.CancelWorker.new()
        |> Oban.insert!()

        ExecutionProfiles.audit(actor, "review.#{action}", id, %{
          reason: reason,
          work_preserved: true
        })

        saved
      end
    end)
    |> notify()
  end

  def valid_result?(%{"summary" => summary, "findings" => findings} = result) do
    map_size(result) == 2 and is_binary(summary) and String.length(summary) in 1..4000 and
      is_list(findings) and length(findings) <= 30 and
      Enum.all?(findings, fn
        %{"severity" => severity, "description" => description} = finding ->
          map_size(finding) == 2 and severity in ~w(high medium low) and
            is_binary(description) and String.length(description) in 1..4000

        _ ->
          false
      end)
  end

  def valid_result?(_), do: false

  defp update_job(job, attrs), do: job |> Job.changeset(attrs) |> Repo.update!()

  defp notify(outcome) do
    ExecutionProfiles.notify()
    outcome
  end
end
