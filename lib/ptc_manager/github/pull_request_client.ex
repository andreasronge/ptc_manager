defmodule PtcManager.GitHub.PullRequestClient do
  @moduledoc "Read-only GitHub REST client for canonical pull-request status."

  @behaviour PtcManager.GitHub.PullRequests

  alias PtcManager.GitHub.Client
  alias PtcManager.Operations.PrPublication

  @impl true
  def status(%PrPublication{pr_number: number, job: %{repository: repository}})
      when is_integer(number) do
    case Client.get_json(repository_url(repository, "/pulls/#{number}")) do
      {:ok, pull} when is_map(pull) ->
        case normalize(pull) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:blocked, reason}
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

  defp normalize(pull) do
    state =
      cond do
        pull["merged_at"] -> "merged"
        pull["state"] == "closed" -> "closed"
        true -> "open"
      end

    result = %{
      pr_number: pull["number"],
      pr_url: pull["html_url"],
      state: state,
      draft: pull["draft"] == true,
      body: pull["body"] || "",
      head_sha: get_in(pull, ["head", "sha"]),
      head_ref: get_in(pull, ["head", "ref"]),
      head_repository: get_in(pull, ["head", "repo", "full_name"]),
      base_ref: get_in(pull, ["base", "ref"]),
      base_repository: get_in(pull, ["base", "repo", "full_name"])
    }

    if valid_normalized?(result), do: {:ok, result}, else: {:error, :invalid_pull_request}
  end

  defp valid_normalized?(result) do
    is_integer(result.pr_number) and result.pr_number > 0 and is_binary(result.pr_url) and
      result.state in ["open", "merged", "closed"] and is_binary(result.head_sha) and
      is_binary(result.head_ref) and is_binary(result.head_repository) and
      is_binary(result.base_ref) and is_binary(result.base_repository)
  end

  defp repository_url(repository, suffix) do
    "https://api.github.com/repos/#{repository.github_owner}/#{repository.github_name}#{suffix}"
  end
end
