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

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        message =
          case Jason.decode(body) do
            {:ok, %{"message" => value}} when is_binary(value) -> value
            _ -> "GitHub returned HTTP #{status}"
          end

        {:error, {:github_http_error, status, message}}

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

  defp decode_items(body) do
    case Jason.decode(body) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, {:invalid_github_json, reason}}
    end
  end
end
