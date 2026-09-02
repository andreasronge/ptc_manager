defmodule PtcManager.GitHub.Client do
  @moduledoc "Read-only GitHub GraphQL/REST client used by synchronization services."

  @behaviour PtcManager.GitHub

  alias PtcManager.Operations.Repository

  @api_version "2026-03-10"
  @per_page 100
  @max_pages 20
  @graphql_url "https://api.github.com/graphql"

  @impl true
  def get_repository(owner, name) when is_binary(owner) and is_binary(name) do
    variables = %{"owner" => owner, "name" => name}

    case graphql(repository_query(), variables, repository_lookup: true) do
      {:ok, %{"repository" => nil}} ->
        {:error, :repository_not_found}

      {:ok, %{"repository" => %{"nameWithOwner" => full_name} = repository}} ->
        if full_name == owner <> "/" <> name,
          do: {:ok, repository},
          else: {:error, :repository_not_found}

      {:ok, _unexpected} ->
        {:error, :unexpected_github_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_open_issues(%Repository{} = repository) do
    fetch_graphql_pages(repository, nil, 1, [])
  end

  @impl true
  def get_issue(%Repository{} = repository, number) when is_integer(number) and number > 0 do
    variables = %{
      "owner" => repository.github_owner,
      "name" => repository.github_name,
      "number" => number
    }

    with {:ok, %{"repository" => %{"issue" => issue}}} when is_map(issue) <-
           graphql(issue_query(), variables) do
      {:ok, normalize_graphql_issue(issue)}
    else
      {:ok, %{"repository" => %{"issue" => nil}}} -> {:error, :github_item_is_pull_request}
      {:ok, _unexpected} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, reason}
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

  defp fetch_graphql_pages(_repository, _cursor, page, _issues) when page > @max_pages,
    do: {:error, :pagination_limit_reached}

  defp fetch_graphql_pages(repository, cursor, page, issues) do
    variables = %{
      "owner" => repository.github_owner,
      "name" => repository.github_name,
      "cursor" => cursor
    }

    with {:ok,
          %{
            "repository" => %{
              "issues" => %{
                "nodes" => nodes,
                "pageInfo" => %{
                  "hasNextPage" => has_next_page,
                  "endCursor" => next_cursor
                }
              }
            }
          }} <- graphql(list_query(), variables),
         true <- is_list(nodes) do
      next_issues = issues ++ Enum.map(nodes, &normalize_graphql_issue/1)

      if has_next_page do
        fetch_graphql_pages(repository, next_cursor, page + 1, next_issues)
      else
        {:ok, next_issues}
      end
    else
      false -> {:error, :unexpected_github_response}
      {:ok, _unexpected} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def normalize_graphql_issue(issue) do
    blocked_by =
      issue
      |> get_in(["blockedBy", "nodes"])
      |> then(fn nodes -> if is_list(nodes), do: Enum.filter(nodes, &is_map/1), else: [] end)

    total_blocked_by = get_in(issue, ["blockedBy", "totalCount"]) || length(blocked_by)

    %{
      "number" => issue["number"],
      "title" => issue["title"],
      "html_url" => issue["url"],
      "body" => issue["body"] || "",
      "state" => normalize_enum(issue["state"]),
      "state_reason" => normalize_enum(issue["stateReason"]),
      "updated_at" => issue["updatedAt"],
      "labels" => get_in(issue, ["labels", "nodes"]) || [],
      "assignees" => get_in(issue, ["assignees", "nodes"]) || [],
      "blocked_by" => Enum.map(blocked_by, &normalize_graphql_blocker/1),
      "blocked_by_overflow" => total_blocked_by > @per_page,
      "blocked_by_unknown_count" =>
        if(total_blocked_by <= @per_page,
          do: max(total_blocked_by - length(blocked_by), 0),
          else: 0
        )
    }
  end

  defp normalize_graphql_blocker(blocker) do
    %{
      "id" => blocker["databaseId"],
      "node_id" => blocker["id"],
      "number" => blocker["number"],
      "title" => blocker["title"],
      "html_url" => blocker["url"],
      "state" => normalize_enum(blocker["state"]),
      "state_reason" => normalize_enum(blocker["stateReason"]),
      "repository" => %{"full_name" => get_in(blocker, ["repository", "nameWithOwner"])}
    }
  end

  defp normalize_enum(value) when is_binary(value), do: value |> String.downcase()
  defp normalize_enum(_value), do: nil

  defp graphql(query, variables, opts \\ []) do
    payload = Jason.encode!(%{"query" => query, "variables" => variables})
    repository_lookup? = opts[:repository_lookup] == true

    with :ok <- require_graphql_token(),
         {:ok, body} <- post(@graphql_url, payload),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"data" => %{"repository" => nil} = data, "errors" => errors}
        when repository_lookup? ->
          if Enum.any?(errors, &(is_map(&1) and &1["type"] == "NOT_FOUND")),
            do: {:ok, data},
            else: {:error, {:github_graphql_error, bounded_errors(errors)}}

        %{"errors" => [_error | _rest] = errors} ->
          {:error, {:github_graphql_error, bounded_errors(errors)}}

        %{"data" => data} when is_map(data) ->
          {:ok, data}

        _unexpected ->
          {:error, :unexpected_github_response}
      end
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_github_json, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_query do
    """
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        issues(states: OPEN, first: 100, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { #{issue_fields()} }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """
  end

  defp repository_query do
    """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { nameWithOwner }
    }
    """
  end

  defp issue_query do
    """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) { #{issue_fields()} }
      }
    }
    """
  end

  defp issue_fields do
    """
    number title url body state stateReason updatedAt
    labels(first: 100) { nodes { name } }
    assignees(first: 100) { nodes { login } }
    blockedBy(first: 100) {
      totalCount
      nodes {
        id databaseId number title url state stateReason
        repository { nameWithOwner }
      }
    }
    """
  end

  defp bounded_errors(errors),
    do: errors |> inspect(limit: 10, printable_limit: 1_000) |> String.slice(0, 1_000)

  defp require_graphql_token do
    case Application.get_env(:ptc_manager, :github_read_token) do
      token when is_binary(token) ->
        if String.trim(token) == "",
          do: {:error, :github_graphql_token_required},
          else: :ok

      _token ->
        {:error, :github_graphql_token_required}
    end
  end

  defp get(url) do
    request(:get, {String.to_charlist(url), request_headers()}, 15_000)
  end

  defp post(url, payload) do
    request =
      {String.to_charlist(url), request_headers(), ~c"application/json",
       String.to_charlist(payload)}

    request(:post, request, 30_000)
  end

  defp request(method, request, timeout) do
    http_options = [timeout: timeout, connect_timeout: 5_000, ssl: ssl_options()]

    case :httpc.request(method, request, http_options, body_format: :binary) do
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

  defp request_headers do
    [
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"user-agent", ~c"ptc-manager-read-only"},
      {~c"x-github-api-version", String.to_charlist(@api_version)}
    ]
    |> maybe_add_token(Application.get_env(:ptc_manager, :github_read_token))
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
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
end
