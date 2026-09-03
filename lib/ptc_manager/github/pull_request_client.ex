defmodule PtcManager.GitHub.PullRequestClient do
  @moduledoc "Read-only GitHub REST client for canonical pull-request status."

  @behaviour PtcManager.GitHub.PullRequests

  alias PtcManager.GitHub.{Client, LinkedIssues}
  alias PtcManager.Operations.PrPublication

  @per_page 100
  @max_pages 20

  @impl true
  def list_open(repository) do
    fetch_open_pages(repository, 1, [])
  end

  @impl true
  def status(%PrPublication{pr_number: number} = publication) when is_integer(number) do
    repository = PrPublication.repository(publication)

    if is_nil(repository) do
      {:blocked, :pull_request_repository_missing}
    else
      fetch_status(repository, number)
    end
  end

  defp fetch_status(repository, number) do
    case Client.get_json(repository_url(repository, "/pulls/#{number}")) do
      {:ok, pull} when is_map(pull) ->
        normalize_with_health(repository, pull)

      {:ok, _unexpected} ->
        {:blocked, :unexpected_github_response}

      {:error, reason} ->
        case classify_error(reason) do
          {:retry, retry_reason} -> {:retry, retry_reason}
          {:error, blocked_reason} -> {:blocked, blocked_reason}
        end
    end
  end

  @impl true
  def discover(%PrPublication{branch_name: branch, job: %{repository: repository}})
      when is_binary(branch) do
    head = URI.encode_www_form("#{repository.github_owner}:#{branch}")
    url = repository_url(repository, "/pulls?state=all&head=#{head}&per_page=10")

    case Client.get_json(url) do
      {:ok, [pull]} when is_map(pull) ->
        normalize_with_health(repository, pull)

      {:ok, []} ->
        {:retry, :agent_pull_request_not_found}

      {:ok, pulls} when is_list(pulls) ->
        {:blocked, :multiple_agent_pull_requests}

      {:ok, _unexpected} ->
        {:blocked, :unexpected_github_response}

      {:error, reason} ->
        case classify_error(reason) do
          {:retry, retry_reason} -> {:retry, retry_reason}
          {:error, blocked_reason} -> {:blocked, blocked_reason}
        end
    end
  end

  @doc false
  def classify_error({:github_http_error, _status, _message, delay_ms} = reason)
      when is_integer(delay_ms),
      do: {:retry, {:after, delay_ms, reason}}

  def classify_error({:github_http_error, status, _message, _delay} = reason)
      when status in 500..599,
      do: {:retry, reason}

  def classify_error({:github_http_error, status, _message, nil} = reason)
      when status in [403, 429],
      do: {:retry, {:after, 60_000, reason}}

  def classify_error({:github_transport_error, _reason} = reason), do: {:retry, reason}
  def classify_error(reason), do: {:error, reason}

  @doc false
  def normalize(pull) do
    state =
      cond do
        pull["merged_at"] -> "merged"
        pull["state"] == "closed" -> "closed"
        true -> "open"
      end

    body = pull["body"] || ""
    base_repository = get_in(pull, ["base", "repo", "full_name"])

    result = %{
      pr_number: pull["number"],
      pr_url: pull["html_url"],
      state: state,
      draft: pull["draft"] == true,
      body: body,
      head_sha: get_in(pull, ["head", "sha"]),
      head_ref: get_in(pull, ["head", "ref"]),
      head_repository: get_in(pull, ["head", "repo", "full_name"]),
      base_sha: get_in(pull, ["base", "sha"]),
      base_ref: get_in(pull, ["base", "ref"]),
      base_repository: base_repository,
      title: pull["title"],
      author_login: get_in(pull, ["user", "login"]),
      linked_issue_numbers: linked_issue_numbers(body, base_repository)
    }

    if valid_normalized?(result), do: {:ok, result}, else: {:error, :invalid_pull_request}
  end

  defp valid_normalized?(result) do
    is_integer(result.pr_number) and result.pr_number > 0 and is_binary(result.pr_url) and
      result.state in ["open", "merged", "closed"] and is_binary(result.head_sha) and
      is_binary(result.head_ref) and is_binary(result.head_repository) and
      is_binary(result.base_sha) and is_binary(result.base_ref) and
      is_binary(result.base_repository) and is_binary(result.title)
  end

  defp normalize_with_health(repository, pull) do
    with {:ok, result} <- normalize(pull),
         {:ok, health} <- health(repository, pull, result.head_sha) do
      {:ok, Map.merge(result, health)}
    else
      {:retry, reason} -> {:retry, reason}
      {:error, reason} -> {:blocked, reason}
    end
  end

  @doc false
  def linked_issue_numbers(body, repository_full_name \\ nil),
    do: LinkedIssues.from_body(body, repository_full_name)

  defp fetch_open_pages(_repository, page, _pulls) when page > @max_pages,
    do: {:blocked, :pull_request_pagination_limit_reached}

  defp fetch_open_pages(repository, page, pulls) do
    url =
      repository_url(
        repository,
        "/pulls?state=open&sort=updated&direction=desc&per_page=#{@per_page}&page=#{page}"
      )

    case Client.get_json(url) do
      {:ok, items} when is_list(items) ->
        case normalize_open_page(items) do
          {:ok, normalized} ->
            next = pulls ++ normalized

            if length(items) < @per_page,
              do: {:ok, next},
              else: fetch_open_pages(repository, page + 1, next)

          {:error, reason} ->
            {:blocked, reason}
        end

      {:ok, _unexpected} ->
        {:blocked, :unexpected_github_response}

      {:error, reason} ->
        case classify_error(reason) do
          {:retry, retry_reason} -> {:retry, retry_reason}
          {:error, blocked_reason} -> {:blocked, blocked_reason}
        end
    end
  end

  defp normalize_open_page(pulls) do
    Enum.reduce_while(pulls, {:ok, []}, fn pull, {:ok, normalized} ->
      case normalize(pull) do
        {:ok, result} ->
          enriched = Map.merge(result, lightweight_health(pull))
          {:cont, {:ok, [enriched | normalized]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  @doc false
  def health_from_responses(pull, combined_status, check_runs) do
    legacy = legacy_checks(combined_status)
    checks = check_runs(check_runs)
    total = legacy.total + checks.total
    failed = legacy.failed + checks.failed
    pending = legacy.pending + checks.pending

    checks_state =
      cond do
        failed > 0 -> "failure"
        legacy.unknown or checks.unknown -> "unknown"
        pending > 0 -> "pending"
        total == 0 -> "none"
        true -> "success"
      end

    %{
      draft: pull["draft"] == true,
      mergeability: mergeability(pull),
      mergeable_state: bounded_state(pull["mergeable_state"]),
      checks_state: checks_state,
      checks_total: total,
      checks_failed: failed,
      checks_pending: pending
    }
  end

  defp health(repository, pull, head_sha) do
    base = "https://api.github.com/repos/#{repository.github_owner}/#{repository.github_name}"

    with {:ok, combined_status} <- health_response("#{base}/commits/#{head_sha}/status"),
         {:ok, check_runs} <-
           health_response("#{base}/commits/#{head_sha}/check-runs?per_page=100") do
      {:ok, health_from_responses(pull, combined_status, check_runs)}
    end
  end

  defp health_response(url) do
    case Client.get_json(url) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> classify_error(reason)
    end
  end

  defp lightweight_health(pull) do
    %{draft: pull["draft"] == true}
  end

  defp legacy_checks(%{"total_count" => 0}),
    do: %{total: 0, failed: 0, pending: 0, unknown: false}

  defp legacy_checks(%{"state" => state, "total_count" => total})
       when state in ["success", "pending", "failure", "error"] and is_integer(total) do
    %{
      total: total,
      failed: if(state in ["failure", "error"], do: 1, else: 0),
      pending: if(state == "pending", do: 1, else: 0),
      unknown: false
    }
  end

  defp legacy_checks(_response), do: %{total: 0, failed: 0, pending: 0, unknown: true}

  defp check_runs(%{"check_runs" => runs} = response) when is_list(runs) do
    observed =
      Enum.reduce(runs, %{total: 0, failed: 0, pending: 0, unknown: false}, fn run, acc ->
        cond do
          run["status"] != "completed" ->
            %{acc | total: acc.total + 1, pending: acc.pending + 1}

          run["conclusion"] in ["success", "neutral", "skipped"] ->
            %{acc | total: acc.total + 1}

          true ->
            %{acc | total: acc.total + 1, failed: acc.failed + 1}
        end
      end)

    case response["total_count"] do
      total when is_integer(total) and total > length(runs) ->
        %{observed | total: total, unknown: true}

      _total ->
        observed
    end
  end

  defp check_runs(_response), do: %{total: 0, failed: 0, pending: 0, unknown: true}

  defp mergeability(%{"draft" => true}), do: "blocked"
  defp mergeability(%{"mergeable_state" => "dirty"}), do: "conflicting"
  defp mergeability(%{"mergeable" => false}), do: "blocked"
  defp mergeability(%{"mergeable" => true, "mergeable_state" => "clean"}), do: "mergeable"

  defp mergeability(%{"mergeable" => true, "mergeable_state" => state})
       when state in ["behind", "blocked", "draft", "unstable"],
       do: "blocked"

  defp mergeability(_pull), do: "unknown"

  defp bounded_state(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp bounded_state(_value), do: nil

  defp repository_url(repository, suffix) do
    "https://api.github.com/repos/#{repository.github_owner}/#{repository.github_name}#{suffix}"
  end
end
