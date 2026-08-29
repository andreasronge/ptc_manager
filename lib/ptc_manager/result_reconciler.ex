defmodule PtcManager.ResultReconciler do
  @moduledoc "Verifies committed implementation branches before GitHub write eligibility."

  alias PtcManager.Operations

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

    case probe.verify(job.repository, job) do
      {:ok, result} ->
        if valid_result?(result) do
          Operations.mark_result_verified(
            job.id,
            job.fencing_token,
            job.result_attempt_token,
            result
          )
        else
          record_failure(job, {:invalid_probe_result, result})
        end

      {:error, reason} ->
        record_failure(job, reason)

      other ->
        reason = {:unexpected_probe_result, other}

        record_failure(job, reason)
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
end
