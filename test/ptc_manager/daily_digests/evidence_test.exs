defmodule PtcManager.DailyDigests.EvidenceTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.DailyDigests.DailyDigest
  alias PtcManager.DailyDigests.Evidence

  @head String.duplicate("f", 40)
  @merged String.duplicate("a", 40)
  @direct String.duplicate("b", 40)
  @next_day String.duplicate("c", 40)
  @merged_later String.duplicate("d", 40)

  defmodule FakeClient do
    def get_json(url) do
      send(Process.get(:daily_evidence_test_pid), {:github_get, url})

      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => String.duplicate("f", 40)}}

        String.contains?(url, "/commits?") ->
          {:ok,
           [
             commit(String.duplicate("b", 40), "Refactor the queue"),
             commit(String.duplicate("d", 40), "Dated today, merged tomorrow"),
             commit(
               String.duplicate("c", 40),
               "Belongs to the next day",
               "2026-08-30T22:00:00Z"
             )
           ]}

        String.contains?(url, "/commits/#{String.duplicate("b", 40)}/pulls") ->
          {:ok, []}

        String.contains?(url, "/commits/#{String.duplicate("d", 40)}/pulls") ->
          {:ok,
           [
             pull_request(
               1723,
               String.duplicate("d", 40),
               "2026-08-30T22:00:00Z",
               "Merged in the next window"
             )
           ]}

        String.contains?(url, "/pulls?") ->
          {:ok,
           [
             pull_request(
               1722,
               String.duplicate("a", 40),
               "2026-08-30T12:00:00Z",
               "Explain the missing build prerequisite"
             ),
             pull_request(
               1723,
               String.duplicate("d", 40),
               "2026-08-30T22:00:00Z",
               "Merged in the next window"
             )
           ]}

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp pull_request(number, merge_sha, merged_at, title) do
      %{
        "number" => number,
        "title" => title,
        "body" => "Adds a concrete error and example.",
        "html_url" => "https://github.com/andreas/runner/pull/#{number}",
        "merged_at" => merged_at,
        "updated_at" => merged_at,
        "merge_commit_sha" => merge_sha,
        "base" => %{"ref" => "main"}
      }
    end

    defp commit(sha, message, committed_at \\ "2026-08-30T12:00:00Z") do
      %{
        "sha" => sha,
        "html_url" => "https://github.com/andreas/runner/commit/#{sha}",
        "commit" => %{
          "message" => message,
          "committer" => %{"date" => committed_at}
        },
        "author" => %{"login" => "andreas"}
      }
    end
  end

  defmodule LargeFakeClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => sha(999)}}

        String.contains?(url, "/commits/") and String.contains?(url, "/pulls?") ->
          {:ok, []}

        String.contains?(url, "/commits?") ->
          {:ok,
           Enum.map(101..140, fn number ->
             %{
               "sha" => sha(number),
               "html_url" => "https://github.com/a/r/commit/#{sha(number)}",
               "commit" => %{
                 "message" => String.duplicate("d", 100),
                 "committer" => %{"date" => "2026-08-30T13:00:00Z"}
               },
               "author" => %{"login" => "maintainer"}
             }
           end)}

        String.contains?(url, "/pulls?") ->
          {:ok,
           Enum.map(1..40, fn number ->
             %{
               "number" => number,
               "title" => String.duplicate("t", 100),
               "body" => String.duplicate("b", 600),
               "html_url" => "https://github.com/a/r/pull/#{number}",
               "merged_at" => "2026-08-30T12:00:00Z",
               "updated_at" => "2026-08-30T12:00:00Z",
               "merge_commit_sha" => sha(number),
               "base" => %{"ref" => "main"}
             }
           end)}

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp sha(number),
      do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")
  end

  defmodule MovingPullRequestClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => sha(999)}}

        String.contains?(url, "/commits?") ->
          {:ok, []}

        String.contains?(url, "/pulls?") ->
          case url
               |> URI.parse()
               |> Map.fetch!(:query)
               |> URI.decode_query()
               |> Map.fetch!("page") do
            "1" ->
              {:ok,
               [pull_request(1722)] ++
                 Enum.map(1..99, fn offset -> unmerged_pull_request(2_000 + offset) end)}

            "2" ->
              # PR 1722 moved from page one while GitHub was being paginated.
              {:ok, [pull_request(1722), pull_request(1724)]}
          end

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp pull_request(number) do
      %{
        "number" => number,
        "title" => "Merged PR #{number}",
        "body" => "A bounded body.",
        "html_url" => "https://github.com/a/r/pull/#{number}",
        "merged_at" => "2026-08-30T12:00:00Z",
        "updated_at" => "2026-08-30T12:00:00Z",
        "merge_commit_sha" => sha(number),
        "base" => %{"ref" => "main"}
      }
    end

    defp unmerged_pull_request(number) do
      pull_request(number)
      |> Map.put("merged_at", nil)
    end

    defp sha(number),
      do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")
  end

  defmodule DisappearingPullRequestClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          Process.put(:stable_pull_scan, 0)
          {:ok, %{"sha" => sha(999)}}

        String.contains?(url, "/commits?") ->
          {:ok, []}

        String.contains?(url, "/pulls?") ->
          page =
            url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("page")

          case page do
            "1" ->
              scan = Process.get(:stable_pull_scan, 0) + 1
              Process.put(:stable_pull_scan, scan)

              items = Enum.map(1..100, fn offset -> unmerged_pull_request(3_000 + offset) end)

              if scan == 1,
                do: {:ok, items},
                else: {:ok, [pull_request(1730) | Enum.take(items, 99)]}

            "2" ->
              # On scan one, PR 1730 moved into page one after page one was
              # read and therefore vanished from this page. Later scans see it.
              {:ok, []}
          end

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp pull_request(number) do
      %{
        "number" => number,
        "title" => "Merged PR #{number}",
        "body" => "A bounded body.",
        "html_url" => "https://github.com/a/r/pull/#{number}",
        "merged_at" => "2026-08-30T12:00:00Z",
        "updated_at" => "2026-08-30T12:00:00Z",
        "merge_commit_sha" => sha(number),
        "base" => %{"ref" => "main"}
      }
    end

    defp unmerged_pull_request(number), do: pull_request(number) |> Map.put("merged_at", nil)

    defp sha(number),
      do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")
  end

  setup do
    Process.put(:daily_evidence_test_pid, self())
    previous = Application.get_env(:ptc_manager, :daily_digest_github_client)
    Application.put_env(:ptc_manager, :daily_digest_github_client, FakeClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ptc_manager, :daily_digest_github_client, previous),
        else: Application.delete_env(:ptc_manager, :daily_digest_github_client)
    end)

    :ok
  end

  test "uses merge time, labels direct-commit time, and fences every query to one head" do
    repository = repository_fixture(%{github_owner: "andreas", github_name: "runner"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["source_head_sha"] == @head
    assert evidence["change_count"] == 2
    assert evidence["pull_request_numbers"] == [1722]
    assert Enum.map(evidence["commits"], & &1["sha"]) == [@merged, @direct]
    assert hd(evidence["commits"])["included_by"] == "pull_request_merged_at"
    assert List.last(evidence["commits"])["included_by"] =~ "committer_date"
    assert hd(evidence["pull_requests"])["title"] =~ "missing build prerequisite"
    refute Enum.any?(evidence["commits"], &(&1["sha"] in [@next_day, @merged_later]))
    refute evidence["evidence_truncated"]

    assert_received {:github_get, head_url}
    assert String.ends_with?(head_url, "/commits/main")

    assert_received {:github_get, pulls_url}
    assert pulls_url =~ "/pulls?"
    assert pulls_url =~ "base=main"
    assert pulls_url =~ "state=closed"

    assert_received {:github_get, stable_pulls_url}
    assert stable_pulls_url == pulls_url

    assert_received {:github_get, commits_url}
    assert commits_url =~ "/commits?"
    assert commits_url =~ "sha=#{@head}"
    refute commits_url =~ "sha=main"
    assert commits_url =~ "since=2026-08-29T22%3A00%3A00Z"
    assert commits_url =~ "until=2026-08-30T22%3A00%3A00Z"

    refute_received {:github_write, _request}
  end

  test "compacts oversized optional prose and marks the manifest as truncated" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, LargeFakeClient)
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["change_count"] == 80
    assert length(evidence["pull_request_numbers"]) == 40
    assert evidence["evidence_truncated"]
    assert Enum.all?(evidence["pull_requests"], &(not Map.has_key?(&1, "body")))
    assert evidence |> Jason.encode!() |> byte_size() <= 60_000
  end

  test "deduplicates pull requests that move across mutable pagination boundaries" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MovingPullRequestClient)
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["pull_request_numbers"] == [1722, 1724]
    assert evidence["change_count"] == 2
  end

  test "rescans until a PR that moved into an already-read page is observed stably" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, DisappearingPullRequestClient)
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["pull_request_numbers"] == [1730]
    assert evidence["change_count"] == 1
    assert Process.get(:stable_pull_scan) == 3
  end
end
