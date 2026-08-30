defmodule PtcManager.GitHubClientTest do
  use ExUnit.Case, async: true

  alias PtcManager.GitHub.{Client, PullRequestClient}

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
