defmodule PtcManager.Publisher do
  @moduledoc "Revalidates and publishes one durable draft-PR effect."

  alias PtcManager.Publications

  def run_once(opts \\ []) do
    case Publications.claim_next() do
      {:ok, nil} -> {:ok, :empty}
      {:ok, publication} -> publish(publication, opts)
      {:error, :publication_already_claimed} -> {:ok, :empty}
      {:error, reason} -> {:error, reason}
    end
  end

  def run_publication(publication_id, opts \\ []) when is_integer(publication_id) do
    case Publications.claim(publication_id) do
      {:ok, publication} -> publish(publication, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(publication, opts) do
    probe = Keyword.get(opts, :probe, Application.fetch_env!(:ptc_manager, :result_probe))
    broker = Keyword.get(opts, :broker, Application.fetch_env!(:ptc_manager, :publish_broker))

    with {:ok, result} <- probe.verify(publication.job.repository, publication.job),
         :ok <- verified_result_matches(publication, result),
         :ok <-
           Publications.renew_claim(
             publication.id,
             publication.fencing_token,
             publication.attempt_token
           ) do
      case broker.publish(publication) do
        {:ok, remote} ->
          Publications.complete(
            publication.id,
            publication.fencing_token,
            publication.attempt_token,
            remote
          )

        {:retry, reason} ->
          record_failure(publication, :retry, reason)

        {:blocked, reason} ->
          record_failure(publication, :blocked, reason)

        other ->
          record_failure(publication, :retry, {:unexpected_broker_result, other})
      end
    else
      {:error, reason} -> record_failure(publication, :retry, {:revalidation_failed, reason})
      {:changed, reason} -> record_failure(publication, :blocked, reason)
    end
  end

  defp verified_result_matches(publication, %{
         base_sha: base_sha,
         head_sha: head_sha,
         diff_digest: diff_digest
       }) do
    if base_sha == publication.base_sha and head_sha == publication.head_sha and
         diff_digest == publication.diff_digest do
      :ok
    else
      {:changed, :verified_branch_changed}
    end
  end

  defp verified_result_matches(_publication, _result), do: {:changed, :invalid_verified_result}

  defp record_failure(publication, disposition, reason) do
    case Publications.fail(
           publication.id,
           publication.fencing_token,
           publication.attempt_token,
           disposition,
           reason
         ) do
      {:ok, _publication} -> {:error, reason}
      {:error, failure} -> {:error, failure}
    end
  end
end
