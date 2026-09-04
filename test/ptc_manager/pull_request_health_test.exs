defmodule PtcManager.PullRequestHealthTest do
  use ExUnit.Case, async: true

  alias PtcManager.GitHub.PullRequestClient

  test "normalizes the labels GitHub reports on a pull request" do
    pull = %{
      "number" => 42,
      "html_url" => "https://github.com/owner/repo/pull/42",
      "state" => "open",
      "title" => "Fix the thing",
      "body" => "Closes #7",
      "labels" => [%{"name" => "ptc:follow-up"}, %{"name" => "bug"}, %{"name" => "bug"}],
      "head" => %{
        "sha" => String.duplicate("b", 40),
        "ref" => "fix",
        "repo" => %{"full_name" => "owner/repo"}
      },
      "base" => %{
        "sha" => String.duplicate("a", 40),
        "ref" => "main",
        "repo" => %{"full_name" => "owner/repo"}
      }
    }

    assert {:ok, result} = PullRequestClient.normalize(pull)
    assert result.labels == ["ptc:follow-up", "bug"]

    assert {:ok, %{labels: []}} = PullRequestClient.normalize(Map.delete(pull, "labels"))
  end

  test "combines GitHub statuses and check runs into a failing conflicting PR" do
    health =
      PullRequestClient.health_from_responses(
        %{"draft" => false, "mergeable" => false, "mergeable_state" => "dirty"},
        %{"state" => "failure", "total_count" => 1},
        %{
          "check_runs" => [
            %{"status" => "completed", "conclusion" => "success"},
            %{"status" => "in_progress", "conclusion" => nil}
          ]
        }
      )

    assert health.mergeability == "conflicting"
    assert health.checks_state == "failure"
    assert health.checks_total == 3
    assert health.checks_failed == 1
    assert health.checks_pending == 1
  end

  test "distinguishes no checks from unavailable check data" do
    pull = %{"draft" => false, "mergeable" => true, "mergeable_state" => "clean"}

    assert %{checks_state: "none", mergeability: "mergeable"} =
             PullRequestClient.health_from_responses(
               pull,
               %{"state" => "pending", "total_count" => 0},
               %{"check_runs" => []}
             )

    assert %{checks_state: "unknown"} =
             PullRequestClient.health_from_responses(pull, nil, nil)

    assert %{checks_state: "unknown"} =
             PullRequestClient.health_from_responses(
               pull,
               nil,
               %{"check_runs" => []}
             )

    assert %{checks_state: "unknown"} =
             PullRequestClient.health_from_responses(
               pull,
               %{"state" => "success", "total_count" => 1},
               nil
             )
  end

  test "requires GitHub's clean merge state before reporting mergeable" do
    statuses = %{"state" => "success", "total_count" => 1}
    checks = %{"check_runs" => []}

    assert %{mergeability: "mergeable"} =
             PullRequestClient.health_from_responses(
               %{"draft" => false, "mergeable" => true, "mergeable_state" => "clean"},
               statuses,
               checks
             )

    assert %{mergeability: "blocked"} =
             PullRequestClient.health_from_responses(
               %{"draft" => false, "mergeable" => true, "mergeable_state" => "blocked"},
               statuses,
               checks
             )
  end

  test "treats a truncated check-run response as unknown" do
    health =
      PullRequestClient.health_from_responses(
        %{"draft" => false, "mergeable" => true, "mergeable_state" => "clean"},
        %{"state" => "success", "total_count" => 1},
        %{
          "total_count" => 101,
          "check_runs" =>
            for(
              _index <- 1..100,
              do: %{"status" => "completed", "conclusion" => "success"}
            )
        }
      )

    assert health.checks_state == "unknown"
    assert health.checks_total == 102
  end

  test "truncated check runs stay unknown even when a visible run is pending" do
    health =
      PullRequestClient.health_from_responses(
        %{"draft" => false, "mergeable" => true, "mergeable_state" => "clean"},
        %{"state" => "success", "total_count" => 1},
        %{
          "total_count" => 101,
          "check_runs" => [
            %{"status" => "in_progress", "conclusion" => nil}
            | for(
                _index <- 2..100,
                do: %{"status" => "completed", "conclusion" => "success"}
              )
          ]
        }
      )

    assert health.checks_state == "unknown"
    assert health.checks_pending == 1
  end
end
