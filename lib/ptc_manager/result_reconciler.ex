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

  # Protocol v2 asks for a report either way, but the branch still decides. A
  # report that is absent or unreadable lowers the evidence recorded with the
  # result; it does not withhold work PtcManager verified itself. Blocking here
  # would turn a swept temporary directory or a host restart into a job that
  # needs a person, for a delivery that is committed and provable.
  defp read_outcome(2, job, opts) do
    case outcome_contract(job) do
      :never_issued -> verify_branch(job, opts, :none)
      :unusable_token -> verify_branch(job, opts, {:error, :report_token_unusable})
      :issued -> read_issued_outcome(job, opts)
    end
  end

  defp read_issued_outcome(job, opts) do
    case OutcomeReport.read(job) do
      {:ok, {:stopped, report}} -> record_stop(job, report)
      {:ok, {:completed, _payload} = report} -> verify_branch(job, opts, {:ok, report})
      :none -> verify_branch(job, opts, :none)
      {:error, reason} -> verify_branch(job, opts, {:error, reason})
    end
  end

  defp outcome_contract(%{stop_report_token: token} = job)
       when is_binary(token) and token != "" do
    if is_nil(OutcomeReport.path_for(job)), do: :unusable_token, else: :issued
  end

  defp outcome_contract(_job), do: :never_issued

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
            # The outcome is durable, so the model-written file has served its
            # purpose. A failed verification deliberately keeps it: that job
            # returns to the queue under the same report token and the next
            # tick must still be able to read it.
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
  # Protocol v1 records nothing, because it never asked for anything to record.
  defp with_completion(result, _job, nil), do: result

  defp with_completion(result, job, outcome) do
    Map.put(
      result,
      :completion,
      OutcomeReport.envelope(
        accepted(outcome, result.head_sha),
        result.head_sha,
        job.review_generation,
        DateTime.utc_now()
      )
    )
  end

  # A report naming another commit describes work this result does not contain,
  # so it is recorded as unusable rather than attached to the wrong head.
  defp accepted({:ok, report}, head_sha) do
    if OutcomeReport.completed_for?(report, head_sha),
      do: {:ok, report},
      else: {:error, :outcome_report_head_mismatch}
  end

  defp accepted(other, _head_sha), do: other

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
