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
end
