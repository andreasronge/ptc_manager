defmodule PtcManager.Reviews do
  @moduledoc "Durable review admission and exact-commit approval, independent of agent claims."
  import Ecto.Query
  alias PtcManager.{Repo, RepoTransaction, ExecutionProfiles}
  alias PtcManager.Operations.Job
  alias PtcManager.Reviews.Round

  @active ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result)
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
    job = Repo.get!(Job, job_id) |> Repo.preload([:repository, :issue, :worktree_allocation])
    snapshot = Keyword.get(opts, :snapshot, PtcManager.Reviews.Snapshot)

    with true <- is_binary(request_id) and byte_size(request_id) in 1..80,
         true <-
           is_map(job.execution_settings) and job.fencing_token == fence and job.state in @active and
             (not held?(job) or job.review_state in ["paused", "running"]),
         {:ok, input} <- snapshot.capture(job) do
      RepoTransaction.immediate(fn ->
        current = Repo.get!(Job, job_id)

        unless current.fencing_token == fence and current.state in @active and
                 (not held?(current) or current.review_state in ["paused", "running"]),
               do: Repo.rollback(:review_not_admissible)

        existing = Repo.get_by(Round, job_id: job_id, request_id: request_id)

        running =
          Repo.one(
            from r in Round, where: r.job_id == ^job_id and r.state in ["queued", "running"]
          )

        attempts = Repo.aggregate(from(r in Round, where: r.job_id == ^job_id), :count)
        count = completed_count(job_id)

        cached =
          Repo.one(
            from r in Round,
              where:
                r.job_id == ^job_id and r.generation == ^current.review_generation and
                  r.state == "completed" and r.head_sha == ^input["head_sha"] and
                  r.diff_digest == ^input["diff_digest"] and r.base_sha == ^input["base_sha"],
              order_by: [desc: r.number],
              limit: 1
          )

        cond do
          existing ->
            existing

          current.review_state == "paused" ->
            :paused

          running ->
            running

          cached ->
            cached

          current.required_review_count == 0 ->
            :skipped

          count >= current.required_review_count ->
            update_job(current, %{review_state: "paused"})
            :paused

          true ->
            attrs = %{
              job_id: job_id,
              fencing_token: fence,
              generation: current.review_generation,
              number: attempts + 1,
              request_id: request_id,
              state: "queued",
              head_sha: input["head_sha"],
              base_sha: input["base_sha"],
              diff_digest: input["diff_digest"],
              input: Map.put(input, "settings", current.execution_settings),
              expires_at:
                DateTime.add(DateTime.utc_now(), timeout_ms(current) + 900_000, :millisecond)
            }

            round = %Round{} |> Round.changeset(attrs) |> Repo.insert!()

            update_job(current, %{
              review_state: "running",
              reviewed_head_sha: nil,
              review_resume_expires_at: nil
            })

            %{round_id: round.id} |> PtcManager.Reviews.Worker.new() |> Oban.insert!()

            ExecutionProfiles.audit("coordinator", "review.requested", job_id, %{
              round: round.number,
              head_sha: round.head_sha
            })

            round
        end
      end)
      |> notify()
    else
      false -> {:error, :review_not_admissible}
      error -> error
    end
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

    Repo.all(from r in Round, where: r.state in ["queued", "running"] and r.expires_at < ^now)
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

      update_job(job, %{
        review_state: state,
        reviewed_head_sha: if(state == "passed", do: round.head_sha)
      })

      ExecutionProfiles.audit("coordinator", "review.completed", job.id, %{
        round: round.number,
        head_sha: round.head_sha,
        state: state
      })

      round
    end)
    |> notify()
  end

  def fail(id, reason) do
    RepoTransaction.immediate(fn ->
      round = Repo.get!(Round, id)

      if round.state in ~w(queued running) do
        round
        |> Round.changeset(%{state: "failed", error: inspect(reason) |> String.slice(0, 500)})
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

  def status(job_id, id) do
    case Repo.get_by(Round, id: id, job_id: job_id) do
      nil ->
        {:error, :review_missing}

      round ->
        if round.state in ~w(queued running) and
             DateTime.compare(round.expires_at, DateTime.utc_now()) != :gt do
          fail(id, :review_expired)
          {:ok, Repo.get!(Round, id)}
        else
          {:ok, round}
        end
    end
  end

  def decide(id, generation, action, attrs, actor) do
    RepoTransaction.immediate(fn ->
      job = Repo.get!(Job, id)

      unless job.review_state in ~w(paused manual) and job.review_generation == generation and
               job.state in @active,
             do: Repo.rollback(:review_decision_stale)

      if action == "continue" do
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
            stop_report_token: PtcManager.Operations.StopReport.new_token(),
            review_state: "resume_pending",
            reviewed_head_sha: nil,
            review_generation: generation + 1,
            review_resume_expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
          })

        %{job_id: id, generation: saved.review_generation}
        |> PtcManager.Reviews.ResumeWorker.new()
        |> Oban.insert!()

        ExecutionProfiles.audit(actor, "review.continued", id, %{
          extra_rounds: extra,
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
