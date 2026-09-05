defmodule PtcManager.GitHubClientTest do
  use ExUnit.Case, async: false

  alias PtcManager.GitHub.{Client, PullRequestClient}
  alias PtcManager.Operations.Repository

  setup do
    previous = Application.get_env(:ptc_manager, :github_read_token)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ptc_manager, :github_read_token),
        else: Application.put_env(:ptc_manager, :github_read_token, previous)
    end)

    :ok
  end

  test "fails before an HTTP request when GraphQL authentication is missing" do
    Application.delete_env(:ptc_manager, :github_read_token)
    repository = %Repository{github_owner: "public-owner", github_name: "public-repo"}

    assert {:error, :github_graphql_token_required} = Client.list_open_issues(repository)
    assert {:error, :github_graphql_token_required} = Client.get_issue(repository, 42)
    assert {:error, :github_graphql_token_required} = Client.viewer_login()
  end

  test "prefers Retry-After response timing" do
    assert Client.retry_delay_ms([{~c"retry-after", ~c"7"}], 1_000) == 7_000
  end

  test "derives rate-limit delay from the reset timestamp" do
    headers = [
      {~c"x-ratelimit-remaining", ~c"0"},
      {~c"x-ratelimit-reset", ~c"1060"}
    ]

    assert Client.retry_delay_ms(headers, 1_000) == 60_000
  end

  test "the PR client preserves a rate-limit retry deadline" do
    reason = {:github_http_error, 403, "rate limited", 42_000}
    assert PullRequestClient.classify_error(reason) == {:retry, {:after, 42_000, reason}}
  end

  test "extracts unique GitHub closing issue references from a PR body" do
    body = """
    Fixes #1701.
    Closes https://github.com/owner/repo/issues/1708
    Resolves: #1701
    Related to #999.
    """

    assert PullRequestClient.linked_issue_numbers(body, "owner/repo") == [1701, 1708]
  end

  test "normalizes GraphQL issues with exact native blockers and overflow" do
    issue = %{
      "number" => 42,
      "title" => "Use the platform",
      "url" => "https://github.com/owner/app/issues/42",
      "body" => "No dependency prose is required.",
      "state" => "OPEN",
      "stateReason" => "REOPENED",
      "createdAt" => "2026-08-20T07:30:00Z",
      "author" => %{"login" => "a-stranger"},
      "updatedAt" => "2026-09-01T08:00:00Z",
      "labels" => %{"nodes" => [%{"name" => "ptc:ready"}]},
      "assignees" => %{"nodes" => [%{"login" => "worker"}]},
      "blockedBy" => %{
        "totalCount" => 101,
        "nodes" => [
          %{
            "id" => "ISSUE_node",
            "databaseId" => 9_001,
            "number" => 7,
            "title" => "Platform prerequisite",
            "url" => "https://github.com/owner/platform/issues/7",
            "state" => "CLOSED",
            "stateReason" => "NOT_PLANNED",
            "repository" => %{"nameWithOwner" => "Owner/Platform"}
          }
        ]
      }
    }

    normalized = Client.normalize_graphql_issue(issue)

    assert normalized["state"] == "open"
    assert normalized["created_at"] == "2026-08-20T07:30:00Z"
    assert normalized["author_login"] == "a-stranger"
    assert normalized["blocked_by_overflow"]
    assert normalized["blocked_by_unknown_count"] == 0
    assert [blocker] = normalized["blocked_by"]
    assert blocker["id"] == 9_001
    assert blocker["node_id"] == "ISSUE_node"
    assert blocker["state_reason"] == "not_planned"
    assert blocker["repository"]["full_name"] == "Owner/Platform"
  end

  test "counts native blockers hidden from the authenticated viewer" do
    issue = %{
      "number" => 42,
      "title" => "Use a private prerequisite",
      "url" => "https://github.com/owner/app/issues/42",
      "body" => "",
      "state" => "OPEN",
      "updatedAt" => "2026-09-01T08:00:00Z",
      "blockedBy" => %{"totalCount" => 2, "nodes" => [nil]}
    }

    normalized = Client.normalize_graphql_issue(issue)
    assert normalized["blocked_by"] == []
    assert normalized["blocked_by_unknown_count"] == 2
    refute normalized["blocked_by_overflow"]
  end

  test "ignores invalid, excessive, and cross-repository closing references" do
    body =
      [
        "Fixes #0",
        "Closes https://github.com/other/project/issues/42",
        "Closes https://github.com/owner/repo/issues/99",
        "Fixes owner/repo#100"
        | Enum.map(1..12, &"Resolves ##{&1}")
      ]
      |> Enum.join("\n")

    assert PullRequestClient.linked_issue_numbers(body, "owner/repo") ==
             [99, 100 | Enum.to_list(1..8)]
  end
end
