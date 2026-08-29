defmodule PtcManager.GitHub.Client do
  @moduledoc "GET-only GitHub REST client used by the synchronization service."

  @behaviour PtcManager.GitHub

  alias PtcManager.Operations.Repository

  @api_version "2022-11-28"
  @per_page 100
  @max_pages 20

  @impl true
  def list_open_issues(%Repository{} = repository) do
    fetch_pages(repository, 1, [])
  end

  @impl true
  def get_issue(%Repository{} = repository, number) when is_integer(number) and number > 0 do
    url =
      "https://api.github.com/repos/#{repository.github_owner}/#{repository.github_name}/issues/#{number}"

    with {:ok, response} <- get(url),
         {:ok, issue} <- decode_issue(response) do
      {:ok, issue}
    end
  end

  @doc false
  def get_json(url) when is_binary(url) do
    with {:ok, body} <- get(url),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_github_json, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pages(_repository, page, _issues) when page > @max_pages,
    do: {:error, :pagination_limit_reached}

  defp fetch_pages(repository, page, issues) do
    url =
      "https://api.github.com/repos/#{repository.github_owner}/#{repository.github_name}/issues" <>
        "?state=open&sort=updated&direction=desc&per_page=#{@per_page}&page=#{page}"

    with {:ok, response} <- get(url),
         {:ok, items} <- decode_items(response) do
      next_issues = issues ++ Enum.reject(items, &Map.has_key?(&1, "pull_request"))

      if length(items) < @per_page do
        {:ok, next_issues}
      else
        fetch_pages(repository, page + 1, next_issues)
      end
    end
  end

  defp get(url) do
    headers =
      [
        {~c"accept", ~c"application/vnd.github+json"},
        {~c"user-agent", ~c"ptc-manager-read-only"},
        {~c"x-github-api-version", String.to_charlist(@api_version)}
      ]
      |> maybe_add_token(Application.get_env(:ptc_manager, :github_read_token))

    ssl_options = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    request = {String.to_charlist(url), headers}
    http_options = [timeout: 15_000, connect_timeout: 5_000, ssl: ssl_options]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        message =
          case Jason.decode(body) do
            {:ok, %{"message" => value}} when is_binary(value) -> value
            _ -> "GitHub returned HTTP #{status}"
          end

        {:error, {:github_http_error, status, message, retry_delay_ms(response_headers)}}

      {:error, reason} ->
        {:error, {:github_transport_error, reason}}
    end
  end

  defp maybe_add_token(headers, token) when is_binary(token) do
    case String.trim(token) do
      "" -> headers
      token -> [{~c"authorization", String.to_charlist("Bearer " <> token)} | headers]
    end
  end

  defp maybe_add_token(headers, _token), do: headers

  @doc false
  def retry_delay_ms(headers, now_seconds \\ System.system_time(:second)) when is_list(headers) do
    normalized =
      Map.new(headers, fn {key, value} ->
        {key |> to_string() |> String.downcase(), value |> to_string() |> String.trim()}
      end)

    with nil <- seconds_delay(normalized["retry-after"]),
         "0" <- normalized["x-ratelimit-remaining"],
         {reset_at, ""} <- Integer.parse(normalized["x-ratelimit-reset"] || "") do
      max(reset_at - now_seconds, 1) * 1_000
    else
      delay when is_integer(delay) -> delay
      _ -> nil
    end
  end

  defp seconds_delay(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> max(seconds, 1) * 1_000
      _ -> nil
    end
  end

  defp seconds_delay(_value), do: nil

  defp decode_items(body) do
    case Jason.decode(body) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, {:invalid_github_json, reason}}
    end
  end

  defp decode_issue(body) do
    case Jason.decode(body) do
      {:ok, %{"pull_request" => _pull_request}} -> {:error, :github_item_is_pull_request}
      {:ok, issue} when is_map(issue) -> {:ok, issue}
      {:ok, _other} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, {:invalid_github_json, reason}}
    end
  end
end
