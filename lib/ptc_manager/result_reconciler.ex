defmodule PtcManager.ResultReconciler do
  @moduledoc "Verifies committed implementation branches before GitHub write eligibility."

  alias PtcManager.Operations
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
              result,
              contract
            )

          if match?({:ok, _job}, outcome) do
            PtcManager.PublisherPoller.wake()
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

  # An agent that knew why it could not finish said so in a file. Prefer that
  # over the probe's technical reason, which can only say the branch is not
  # usable and never why.
  defp record_failure(job, reason) do
    case StopReport.read(job) do
      {:ok, report} -> record_stop(job, report)
      _no_report -> record_probe_failure(job, reason)
    end
  end

  defp record_stop(job, report) do
    case Operations.record_job_stop_report(job.id, report) do
      {:ok, _job} ->
        StopReport.discard(job)
        {:error, {:agent_stopped, report["reason_code"]}}

      {:error, _reason} = error ->
        error
    end
  end

  defp record_probe_failure(job, reason) do
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
