defmodule PtcManager.Reviews.ResumeWorker do
  # An acknowledgement that fails on a busy database orphans the attempt in
  # `executing`; Oban's lifeline then re-runs it, and every step re-checks the
  # job's generation, so a repeat is a no-op rather than a second writer.
  use Oban.Worker,
    queue: :automations,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias PtcManager.{Repo, RepoTransaction}
  alias PtcManager.Operations.Job
  @impl true
  def perform(%Oban.Job{args: %{"job_id" => id, "generation" => generation}}) do
    if PtcManager.OperationalMode.active?() and
         not Application.get_env(:ptc_manager, :demo_mode, false),
       do: resume(id, generation),
       else: {:snooze, 30}
  end

  defp resume(id, generation) do
    adapter =
      Application.get_env(:ptc_manager, :review_resume_adapter, PtcManager.Dispatch.HerdrAdapter)

    case PtcManager.Reviews.Recovery.prepare(id, generation, adapter) do
      {:ok, %Job{review_resume_mode: "assessment"} = job} ->
        case PtcManager.Reviews.start_retry(job) do
          {:error, :database_busy} ->
            {:snooze, 10}

          {:error, :stale_continuation} ->
            :ok

          {:error, _} ->
            finish(id, generation, {:error, :review_admission_failed}, false)
            :ok

          {:ok, _} ->
            :ok
        end

      {:ok, %Job{}} ->
        claim_and_launch(id, generation)

      {:ok, {:recovery_failed, _}} ->
        :ok

      {:error, reason} when reason in [:recovery_busy, :database_busy] ->
        {:snooze, 10}

      {:error, :stale_continuation} ->
        :ok

      {:error, _} ->
        finish(id, generation, {:error, :retained_workspace_not_ready}, false)
        :ok
    end
  end

  defp claim_and_launch(id, generation) do
    case PtcManager.Operations.claim_review_continuation(id, generation) do
      {:ok, job} ->
        launch(job)

      {:error, reason}
      when reason in [
             :dispatch_capacity,
             :recovery_busy,
             :worker_unavailable,
             :database_busy,
             :merge_priority,
             :delivery_priority
           ] ->
        {:snooze, 10}

      {:error, reason} when reason in [:stale_continuation, :continuation_already_claimed] ->
        :ok

      {:error, _reason} ->
        finish(id, generation, {:error, :retained_workspace_not_ready}, false)
        :ok
    end
  end

  defp launch(job) do
    adapter =
      Application.get_env(:ptc_manager, :review_resume_adapter, PtcManager.Dispatch.HerdrAdapter)

    outcome =
      try do
        adapter.resume_review_job(job)
      rescue
        _ -> {:error, :continuation_failed}
      end

    finish(job.id, job.review_generation, outcome, true, job.review_resume_expires_at)
    :ok
  end

  defp finish(id, generation, outcome, reserved?, reservation \\ nil) do
    RepoTransaction.immediate(fn ->
      current = Repo.get!(Job, id)

      if PtcManager.Reviews.active_job?(current) and
           (current.review_state in ["resume_pending", "changes_requested"] or
              (current.review_state == "passed" and current.review_resume_mode == "publication")) and
           current.review_generation == generation and
           (reserved? or is_nil(current.review_resume_expires_at)) do
        success = match?({:ok, _}, outcome)

        current
        |> Job.changeset(%{
          state:
            if(success,
              do: "working",
              else: failure_state(outcome, reserved?, current.state)
            ),
          review_state:
            if(success,
              do:
                if(current.review_resume_mode == "publication",
                  do: "passed",
                  else: "changes_requested"
                ),
              else: "paused"
            ),
          review_resume_expires_at: nil,
          last_error: if(not success, do: failure_message(outcome))
        })
        |> Repo.update!()
      else
        if reserved? and current.review_state in ~w(manual cancelled) and
             current.review_generation == generation + 1 and
             current.review_resume_expires_at == reservation do
          current |> Job.changeset(%{review_resume_expires_at: nil}) |> Repo.update!()

          %{job_id: id, generation: current.review_generation}
          |> PtcManager.Reviews.CancelWorker.new()
          |> Oban.insert!()
        end
      end
    end)

    PtcManager.ExecutionProfiles.notify()
  end

  defp failure_state({:error, {:continuation_not_started, _}}, _reserved?, _state), do: "blocked"
  defp failure_state(_, true, _state), do: "reconciling"
  defp failure_state(_, false, state), do: state

  defp failure_message({:error, {:continuation_not_started, reason}}) do
    "Continuation did not start (#{failure_code(reason)}). The previous agent is stopped and the work is preserved. Continue to retry."
  end

  defp failure_message({:error, reason}) do
    "Continuation could not start (#{failure_code(reason)}); the work is preserved. Confirm the retained agent state before retrying."
  end

  # Keep native error codes, never agent text or raw command output.
  defp failure_code({:herdr_exit, status, output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"code" => code}}} when is_binary(code) ->
        if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, code),
          do: code,
          else: "herdr_exit_#{status}"

      _ ->
        "herdr_exit_#{status}"
    end
  end

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(_), do: "continuation_failed"
end
