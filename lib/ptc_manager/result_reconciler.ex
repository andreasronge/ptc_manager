defmodule PtcManager.ResultReconciler do
  @moduledoc "Verifies committed implementation branches before GitHub write eligibility."

  alias PtcManager.Operations
  alias PtcManager.Operations.OutcomeReport
  alias PtcManager.Operations.StopReport
  alias PtcManager.Repository.Contract

  def run_once(opts \\ []) do
    case Operations.claim_next_result_job() do
      {:ok, nil} -> {:ok, :empty}
      {:ok, job} -> verify_job(job, opts)
      {:error, :result_already_claimed} -> {:ok, :empty}
    end
  end

  def run_job(job_id, opts \\ []) when is_integer(job_id) do
    case Operations.claim_result_job(job_id) do
      {:ok, job} -> verify_job(job, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_job(job, opts) do
    # An agent that said it could not finish outranks whatever its branch looks
    # like. A partial commit that happens to verify is not a delivery, and
    # publishing it would ship work the agent itself declared incomplete.
    if PtcManager.Reviews.held?(job) do
      record_failure(job, :review_decision_required)
    else
      job |> Operations.result_protocol_version() |> read_outcome(job, opts)
    end
  end

  # Protocol v1 could only say "I could not continue", so anything other than a
  # stop report means the branch decides.
  defp read_outcome(1, job, opts) do
    case StopReport.read(job) do
      {:ok, report} -> record_stop(job, report)
      _no_usable_report -> verify_branch(job, opts, nil)
    end
  end

  # Protocol v2 owes exactly one report for the attempt. A missing or unusable
  # one is a permanent condition: the file will not improve on the next tick,
  # so re-recording the same error would hold the single reconciliation task in
  # a loop. It is handed to the maintainer instead, with the worktree retained.
  defp read_outcome(2, job, opts) do
    case outcome_contract(job) do
      :never_issued ->
        # PtcManager never gave this attempt a path to write to, so there is no
        # report to owe. Its own omission is not charged to the agent.
        verify_branch(job, opts, nil)

      :unusable_token ->
        # A token exists but cannot name a file inside the output directory.
        # That is a defect in PtcManager's own state, not a benign omission, and
        # waiving the contract here would publish on branch evidence alone.
        hand_to_maintainer(job, "The job's report token is not usable as a file name.")

      :issued ->
        read_issued_outcome(job, opts)
    end
  end

  defp read_issued_outcome(job, opts) do
    case OutcomeReport.read(job) do
      {:ok, {:stopped, report}} ->
        record_stop(job, report)

      {:ok, {:completed, _payload} = report} ->
        verify_branch(job, opts, report)

      :none ->
        # Deliberately not "the agent finished": the file is equally absent when
        # the pane was killed, the host restarted, or the agent wrote the other
        # protocol's path. Naming a cause here would point the maintainer away
        # from the pane and worktree that hold the real one.
        hand_to_maintainer(job, "No outcome report was written for this attempt.")

      {:error, reason} ->
        hand_to_maintainer(job, "The outcome report could not be read (#{reason}).")

      other ->
        hand_to_maintainer(job, "The outcome report reader returned #{inspect(other)}.")
    end
  end

  defp outcome_contract(%{stop_report_token: token} = job)
       when is_binary(token) and token != "" do
    if is_nil(OutcomeReport.path_for(job)), do: :unusable_token, else: :issued
  end

  defp outcome_contract(_job), do: :never_issued

  # Terminal by construction: the transition is fenced, ends the attempt, flags
  # the worktree for attention, and takes the job out of the reconciliation
  # queue, so a permanently unreadable file is decided by a person instead of
  # re-read on every tick.
  defp hand_to_maintainer(job, reason) do
    case Operations.record_outcome_report_failure(
           job.id,
           job.fencing_token,
           job.result_attempt_token,
           reason
         ) do
      {:ok, _job} -> {:error, {:outcome_report_unusable, job.id}}
      {:error, _reason} = error -> error
    end
  end

  defp verify_branch(job, opts, report) do
    probe = Keyword.get(opts, :probe, Application.fetch_env!(:ptc_manager, :result_probe))
    contract_provider = Keyword.get(opts, :contract_provider, PtcManager.Repository.Contract)

    case probe.verify(job.repository, job) do
      {:ok, result} ->
        with true <- valid_result?(result),
             {:ok, contract} <- publication_contract(job, result, contract_provider) do
          outcome =
            Operations.mark_result_verified(
              job.id,
              job.fencing_token,
              job.result_attempt_token,
              with_completion(result, job, report),
              contract
            )

          if match?({:ok, _job}, outcome) do
            # The outcome is durable now, so the model-written file has served
            # its purpose. Protocol v2 writes one on success too, and the output
            # directory is shared by every agent under one worker identity, so
            # leaving it there would keep one job's prose readable by the next.
            discard_report(job)
            PtcManager.PublisherPoller.wake()
          else
            if outcome == {:error, :independent_review_required},
              do:
                PtcManager.Reviews.pause(
                  job.id,
                  "Independent review required before publication.",
                  job
                )
          end

          outcome
        else
          false -> record_failure(job, {:invalid_probe_result, result})
          {:error, reason} -> record_failure(job, {:repository_contract_invalid, reason})
        end

      {:error, reason} ->
        record_failure(job, reason)

      other ->
        reason = {:unexpected_probe_result, other}

        record_failure(job, reason)
    end
  end

  # A completed report is attached only when PtcManager's own probe found the
  # same head. The material stays reported evidence either way: it cannot make
  # a result publishable, and a mismatch discards the report rather than the
  # result.
  defp with_completion(result, _job, nil), do: result

  defp with_completion(result, job, report) do
    accepted =
      if OutcomeReport.completed_for?(report, result.head_sha),
        do: {:ok, report},
        else: {:error, :outcome_report_head_mismatch}

    Map.put(
      result,
      :completion,
      OutcomeReport.envelope(accepted, result.head_sha, job.review_generation, DateTime.utc_now())
    )
  end

  # Both deletes are idempotent, so nothing needs to know which protocol wrote
  # the file — and doing both also removes a report an agent left at the other
  # protocol's path.
  defp discard_report(job) do
    StopReport.discard(job)
    OutcomeReport.discard(job)
  end

  defp record_stop(job, report) do
    case Operations.record_job_stop_report(
           job.id,
           job.fencing_token,
           job.result_attempt_token,
           report
         ) do
      {:ok, _job} ->
        discard_report(job)
        {:error, {:agent_stopped, report["reason_code"]}}

      {:error, _reason} = error ->
        error
    end
  end

  defp record_failure(job, reason) do
    _ =
      Operations.record_result_error(
        job.id,
        job.fencing_token,
        job.result_attempt_token,
        reason
      )

    {:error, reason}
  end

  defp valid_result?(%{
         base_sha: base_sha,
         head_sha: head_sha,
         diff_digest: diff_digest,
         commit_count: commit_count
       }) do
    valid_sha?(base_sha) and valid_sha?(head_sha) and
      is_binary(diff_digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, diff_digest) and
      is_integer(commit_count) and commit_count > 0
  end

  defp valid_result?(_result), do: false

  defp valid_sha?(sha), do: PtcManager.Operations.Job.valid_sha?(sha)

  defp publication_contract(%{publication_source: "agent"}, _result, _provider),
    do: {:ok, nil}

  defp publication_contract(job, result, provider) do
    with {:ok, contract} <- provider.for_result(job, result),
         :ok <- Contract.require_publication_verification(contract) do
      {:ok, contract}
    end
  end
end
