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
    gate = Keyword.get(opts, :gate, PtcManager.Repository.PrePublicationGate)

    with {:ok, result} <-
           tagged(probe.verify(publication.job.repository, publication.job), :revalidation),
         :ok <- verified_result_matches(publication, result),
         {:ok, :renewed} <-
           tagged(
             Publications.renew_claim(
               publication.id,
               publication.fencing_token,
               publication.attempt_token
             )
             |> then(fn
               :ok -> {:ok, :renewed}
               error -> error
             end),
             :revalidation
           ),
         {:ok, gate_result} <- tagged(run_gate(publication, gate), :gate),
         {:ok, publication} <- tagged(record_gate_result(publication, gate_result), :gate),
         :ok <- passing_gate_matches(publication) do
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
      {:error, {:revalidation, reason}} ->
        record_failure(publication, :retry, {:revalidation_failed, reason})

      {:error, {:gate, reason}} ->
        record_failure(publication, :blocked, {:pre_publication_gate_failed, reason})

      {:changed, reason} ->
        record_failure(publication, :blocked, reason)
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

  defp run_gate(publication, gate) do
    task =
      Task.async(fn ->
        try do
          gate.verify(publication)
        rescue
          error -> {:error, {:gate_exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {:gate_exit, kind, reason}}
        end
      end)

    await_gate(task, publication, gate_renewal_interval_ms())
  end

  defp await_gate(task, publication, interval_ms) do
    case Task.yield(task, interval_ms) do
      {:ok, result} ->
        case renew_claim(publication) do
          :ok -> result
          {:error, reason} -> {:error, {:claim_renewal_failed, reason}}
        end

      {:exit, reason} ->
        {:error, {:gate_task_exited, reason}}

      nil ->
        case renew_claim(publication) do
          :ok ->
            await_gate(task, publication, interval_ms)

          {:error, reason} ->
            Task.shutdown(task, :brutal_kill)
            {:error, {:claim_renewal_failed, reason}}
        end
    end
  end

  defp renew_claim(publication) do
    Publications.renew_claim(
      publication.id,
      publication.fencing_token,
      publication.attempt_token
    )
  end

  defp gate_renewal_interval_ms do
    claim_timeout_ms =
      Application.get_env(:ptc_manager, :publication_claim_timeout_ms, 180_000)

    configured_ms =
      Application.get_env(:ptc_manager, :publication_gate_renewal_interval_ms, 60_000)

    configured_ms
    |> max(1)
    |> min(max(div(claim_timeout_ms, 3), 1))
  end

  defp record_gate_result(publication, :already_passed), do: {:ok, publication}

  defp record_gate_result(publication, evidence) when is_map(evidence) do
    Publications.record_pre_publication_gate(
      publication.id,
      publication.fencing_token,
      publication.attempt_token,
      evidence
    )
  end

  defp passing_gate_matches(%{
         head_sha: head_sha,
         job:
           %PtcManager.Operations.Job{
             pre_publication_status: "passed",
             pre_publication_verified_sha: head_sha,
             pre_publication_exit_status: 0
           } = job
       }) do
    if PtcManager.Repository.Contract.frozen_publication_digest_matches?(job),
      do: :ok,
      else: {:changed, :pre_publication_gate_config_changed}
  end

  defp passing_gate_matches(_publication), do: {:changed, :pre_publication_gate_failed}

  defp tagged({:ok, value}, _stage), do: {:ok, value}
  defp tagged({:error, reason}, stage), do: {:error, {stage, reason}}

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
