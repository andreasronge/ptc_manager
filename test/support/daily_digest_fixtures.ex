defmodule PtcManager.DailyDigestFixtures do
  alias PtcManager.DailyDigests.Input
  alias PtcManager.Operations.{AgentAction, Repository}
  alias PtcManager.Repo

  def selection(repository, digest, numbers \\ [1722]) do
    time = DateTime.add(digest.window_started_at, 60) |> DateTime.to_iso8601()

    pulls =
      Enum.map(numbers, fn number ->
        %{
          "number" => number,
          "title" => "Delivered improvement",
          "body" => %{"summary" => "Useful change"},
          "body_coverage" => "complete",
          "base_ref" => repository.default_branch,
          "html_url" =>
            "https://github.com/#{repository.github_owner}/#{repository.github_name}/pull/#{number}",
          "merged_at" => time,
          "merge_commit_sha" => String.duplicate("a", 40)
        }
      end)

    %{
      "source_head_sha" => String.duplicate("8", 40),
      "change_count" => length(pulls),
      "pull_request_numbers" => numbers,
      "pull_requests" => pulls,
      "commits" =>
        Enum.map(
          pulls,
          &%{
            "included_by" => "pull_request_merged_at",
            "pull_request_number" => &1["number"],
            "sha" => &1["merge_commit_sha"],
            "included_at" => time
          }
        )
    }
  end

  def prepare(digest, numbers \\ [1722]) do
    repository = Repo.get!(Repository, digest.repository_id)
    action = Repo.get!(AgentAction, digest.agent_action_id)

    {:ok, input} =
      Input.prepare(
        repository,
        digest,
        selection(repository, digest, numbers),
        DateTime.add(digest.window_ended_at, 1)
      )

    action
    |> AgentAction.changeset(%{
      prompt: action.prompt <> "\n" <> Input.block(input),
      target_snapshot: Map.merge(action.target_snapshot, input.snapshot)
    })
    |> Repo.update!()
  end

  def result(action, attrs \\ %{}) do
    snapshot = action.target_snapshot
    numbers = snapshot["trusted_pull_request_numbers"]

    Map.merge(
      %{
        "status" =>
          if(snapshot["trusted_change_count"] == 0, do: "no-changes", else: "published"),
        "title" => "A steadier build day",
        "summary" => "Build feedback is clearer.",
        "what_shipped" =>
          Enum.map(
            numbers,
            &%{
              "source_id" => "pr:#{&1}",
              "summary" => "Build feedback improved.",
              "why_it_matters" => "Errors are easier to understand."
            }
          ),
        "what_we_learned" => [],
        "window_started_at" => snapshot["window_started_at"],
        "window_ended_at" => snapshot["window_ended_at"],
        "source_head_sha" => snapshot["trusted_source_head_sha"],
        "change_count" => snapshot["trusted_change_count"],
        "pull_request_numbers" => numbers,
        "evidence_sha256" => snapshot["trusted_evidence_sha256"]
      },
      attrs
    )
  end
end
