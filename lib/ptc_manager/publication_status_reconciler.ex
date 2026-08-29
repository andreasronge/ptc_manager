defmodule PtcManager.PublicationStatusReconciler do
  @moduledoc "Discovers agent-created PRs and reconciles canonical status through completion."

  alias PtcManager.Publications

  def run_once(opts \\ []) do
    client =
      Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :pull_request_client))

    case reconcile_open(client) do
      {:retry_after, _delay_ms} = retry ->
        retry

      status_result ->
        discovery_result =
          case Publications.next_agent_for_discovery() do
            nil -> {:ok, :empty}
            publication -> discover_agent_publication(client, publication)
          end

        combine_results(status_result, discovery_result)
    end
  end

  defp discover_agent_publication(client, publication) do
    if Code.ensure_loaded?(client) and function_exported?(client, :discover, 1) do
      case client.discover(publication) do
        {:ok, result} ->
          Publications.record_agent_publication(publication.id, result)

        {:retry, {:after, delay_ms, _reason} = reason} when is_integer(delay_ms) ->
          record_discovery_retry(publication.id, reason, delay_ms)

        {:retry, reason} ->
          record_discovery_retry(publication.id, reason, interval())

        {:blocked, reason} ->
          Publications.block_agent_discovery(publication.id, reason)

        other ->
          Publications.block_agent_discovery(
            publication.id,
            {:unexpected_discovery_result, other}
          )
      end
    else
      Publications.block_agent_discovery(publication.id, :pull_request_discovery_unavailable)
    end
  end

  @doc false
  def combine_results({:retry_after, left}, {:retry_after, right}),
    do: {:retry_after, max(left, right)}

  def combine_results(_status, {:retry_after, _delay_ms} = retry), do: retry
  def combine_results({:retry_after, _delay_ms} = retry, _discovery), do: retry
  def combine_results(_status, {:error, _reason} = error), do: error
  def combine_results({:error, _reason} = error, _discovery), do: error
  def combine_results(_status, {:ok, value}) when value != :empty, do: {:ok, value}
  def combine_results(status, {:ok, :empty}), do: status

  defp record_discovery_retry(publication_id, reason, delay_ms) do
    case Publications.record_agent_discovery_retry(publication_id, reason, delay_ms) do
      {:ok, _publication} -> {:retry_after, delay_ms}
      {:error, failure} -> {:error, failure}
    end
  end

  defp reconcile_open(client) do
    case Publications.next_open_for_status() do
      nil ->
        {:ok, :empty}

      publication ->
        case client.status(publication) do
          {:ok, result} ->
            outcome = Publications.record_remote_status(publication.id, result)
            if result.state in ["merged", "closed"], do: PtcManager.WorktreePoller.wake()
            outcome

          {:retry, {:after, delay_ms, _reason} = reason} when is_integer(delay_ms) ->
            case record_error(publication.id, reason) do
              {:error, ^reason} -> {:retry_after, delay_ms}
              other -> other
            end

          {:retry, reason} ->
            record_error(publication.id, reason)

          {:blocked, reason} ->
            record_error(publication.id, reason)

          other ->
            record_error(publication.id, {:unexpected_status_result, other})
        end
    end
  end

  defp record_error(publication_id, reason) do
    case Publications.record_status_error(publication_id, reason) do
      {:ok, _publication} -> {:error, reason}
      {:error, failure} -> {:error, failure}
    end
  end

  defp interval,
    do: Application.get_env(:ptc_manager, :publication_status_interval_ms, 60_000)
end
