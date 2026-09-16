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
      {:ok, report} -> record_stop(job, report, 1)
      _no_usable_report -> verify_branch(job, opts, nil)
    end
  end

  # Protocol v2 owes exactly one report for the attempt. A missing or unusable
  # one is a permanent condition: the file will not improve on the next tick,
  # so re-recording the same error would hold the single reconciliation task in
  # a loop. It is handed to the maintainer instead, with the worktree retained.
  defp read_outcome(2, job, opts) do
    if is_nil(OutcomeReport.path_for(job)) do
      # No token was ever issued, so no contract was handed over. That is
      # PtcManager's own omission and must not be charged to the agent.
      verify_branch(job, opts, nil)
    else
      case OutcomeReport.read(job) do
        {:ok, {:stopped, report}} ->
          record_stop(job, report, 2)

        {:ok, {:completed, _payload} = report} ->
          verify_branch(job, opts, report)

        :none ->
          hand_to_maintainer(
            job,
            "The agent finished without writing its required outcome report."
          )

        {:error, reason} ->
          hand_to_maintainer(
            job,
            "The agent's outcome report could not be read as either outcome (#{reason})."
          )

        other ->
          hand_to_maintainer(job, "The outcome report reader returned #{inspect(other)}.")
      end
    end
  end

  # Terminal and visible: pausing takes the job out of the reconciliation queue,
  # so the condition is decided by a person rather than retried forever.
  defp hand_to_maintainer(job, reason) do
    PtcManager.Reviews.pause(job.id, reason, job)
    {:error, {:outcome_report_unusable, job.id}}
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

  defp discard_report(job, 1), do: StopReport.discard(job)
  defp discard_report(job, 2), do: OutcomeReport.discard(job)

  defp record_stop(job, report, protocol) do
    case Operations.record_job_stop_report(
           job.id,
           job.fencing_token,
           job.result_attempt_token,
           report
         ) do
      {:ok, _job} ->
        discard_report(job, protocol)
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

  defp valid_sha?(sha),
    do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, sha)

  defp publication_contract(%{publication_source: "agent"}, _result, _provider),
    do: {:ok, nil}

  defp publication_contract(job, result, provider) do
    with {:ok, contract} <- provider.for_result(job, result),
         :ok <- Contract.require_publication_verification(contract) do
      {:ok, contract}
    end
  end
end
