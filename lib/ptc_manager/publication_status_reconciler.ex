defmodule PtcManager.PublicationStatusReconciler do
  @moduledoc "Discovers agent-created PRs and reconciles canonical status through completion."

  alias PtcManager.Gateway
  alias PtcManager.Operations
  alias PtcManager.Publications

  def run_once(opts \\ []) do
    client =
      Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :pull_request_client))

    external_enabled =
      Keyword.get(
        opts,
        :external,
        Application.get_env(:ptc_manager, :external_pr_reconcile_enabled, false)
      )

    external_result = if external_enabled, do: reconcile_external(client), else: {:ok, :empty}

    case reconcile_open(client, external_enabled) do
      {:retry_after, _delay_ms} = retry ->
        retry

      status_result ->
        discovery_result =
          case Publications.next_agent_for_discovery() do
            nil ->
              {:ok, :empty}

            publication ->
              Operations.with_repository_lifecycle_lock(publication.repository_id, fn ->
                case PtcManager.Repo.get(PtcManager.Operations.PrPublication, publication.id) do
                  nil -> {:ok, :repository_removed}
                  _current_publication -> discover_agent_publication(client, publication)
                end
              end)
          end

        status_result
        |> combine_results(discovery_result)
        |> combine_results(external_result)
        # A merged or moved member pull request changes what a run does next.
        |> tap(fn _result -> PtcManager.Collections.reconcile_all() end)
    end
  end

  defp reconcile_external(client) do
    if supports?(client, :list_open, 1) do
      PtcManager.Operations.list_repositories()
      |> Enum.filter(& &1.enabled)
      |> Enum.reduce_while({:ok, :empty}, fn repository, _acc ->
        result =
          Operations.with_repository_lifecycle_lock(repository.id, fn ->
            reconcile_external_repository(client, repository)
          end)

        case result do
          {:ok, :repository_removed} -> {:cont, {:ok, :empty}}
          {:ok, _summary} = success -> {:cont, success}
          {:retry_after, _delay_ms} = retry -> {:halt, retry}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:ok, :empty}
    end
  end

  defp reconcile_external_repository(client, repository) do
    case Operations.get_repository(repository.id) do
      nil ->
        {:ok, :repository_removed}

      current_repository ->
        case Gateway.call(client, :list_open, [current_repository]) do
          {:ok, pulls} ->
            with {:ok, confirmed_pulls} <-
                   confirm_missing_external(client, current_repository, pulls),
                 {:ok, summary} <-
                   Publications.sync_external_open_pull_requests(
                     current_repository,
                     confirmed_pulls
                   ) do
              {:ok, summary}
            end

          {:retry, {:after, delay_ms, _reason}} when is_integer(delay_ms) ->
            {:retry_after, delay_ms}

          {:retry, reason} ->
            {:error, reason}

          {:blocked, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_pull_request_list_result, other}}
        end
    end
  end

  defp confirm_missing_external(client, repository, pulls) do
    Publications.external_missing_candidates(repository, pulls)
    |> Enum.reduce_while({:ok, pulls}, fn publication, {:ok, confirmed_pulls} ->
      case Gateway.call(client, :status, [publication]) do
        {:ok, %{state: "open"} = status} ->
          {:cont, {:ok, [status | confirmed_pulls]}}

        {:ok, %{state: state} = status} when state in ["merged", "closed"] ->
          case Publications.record_remote_status(publication.id, status) do
            {:ok, _publication} -> {:cont, {:ok, confirmed_pulls}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:retry, {:after, delay_ms, _reason}} when is_integer(delay_ms) ->
          {:halt, {:retry_after, delay_ms}}

        {:retry, reason} ->
          {:halt, {:error, reason}}

        {:blocked, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:unexpected_pull_request_status_result, other}}}
      end
    end)
  end

  defp discover_agent_publication(client, publication) do
    if supports?(client, :discover, 1) do
      case Gateway.call(client, :discover, [publication]) do
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

  defp reconcile_open(client, include_external) do
    case Publications.next_open_for_status(include_external) do
      nil ->
        {:ok, :empty}

      publication ->
        Operations.with_repository_lifecycle_lock(publication.repository_id, fn ->
          reconcile_open_publication(client, publication)
        end)
    end
  end

  defp reconcile_open_publication(client, publication) do
    case PtcManager.Repo.get(PtcManager.Operations.PrPublication, publication.id) do
      nil ->
        {:ok, :repository_removed}

      _current_publication ->
        case Gateway.call(client, :status, [publication]) do
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

  defp supports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp supports?(%module{}, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity + 1)
  end
end
