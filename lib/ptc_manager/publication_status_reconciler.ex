defmodule PtcManager.PublicationStatusReconciler do
  @moduledoc "Reconciles published PRs so merged or closed work leaves the active queue."

  alias PtcManager.Publications

  def run_once(opts \\ []) do
    client = Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :publish_broker))

    case Publications.next_open_for_status() do
      nil ->
        {:ok, :empty}

      publication ->
        case client.status(publication) do
          {:ok, result} ->
            Publications.record_remote_status(publication.id, result)

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
end
