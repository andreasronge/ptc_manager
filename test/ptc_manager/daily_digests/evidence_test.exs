defmodule PtcManager.DailyDigests.EvidenceTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.DailyDigests.DailyDigest
  alias PtcManager.DailyDigests.Evidence

  @head String.duplicate("f", 40)
  @merged String.duplicate("a", 40)
  @direct String.duplicate("b", 40)
  @next_day String.duplicate("c", 40)
  @merged_later String.duplicate("d", 40)

  defmodule Fixture do
    @moduledoc false

    @doc "A deterministic 40-hex sha derived from a pull request number."
    def sha(number),
      do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")

    @doc "A merged pull request as the GitHub list endpoint returns it."
    def pull_request(number, overrides \\ %{}) do
      Map.merge(
        %{
          "number" => number,
          "title" => "Merged PR #{number}",
          "body" => "A bounded body.",
          "html_url" => "https://github.com/a/r/pull/#{number}",
          "merged_at" => "2026-08-30T12:00:00Z",
          "updated_at" => "2026-08-30T12:00:00Z",
          "merge_commit_sha" => sha(number),
          "head" => %{"sha" => sha(number + 100_000)},
          "base" => %{"ref" => "main"}
        },
        overrides
      )
    end
  end

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

  # A pull request merged long before the window, whose merge commit GitHub no
  # longer reports. The digest has no reason to look at it at all.
  defmodule StalePullClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") -> {:ok, %{"sha" => String.duplicate("f", 40)}}
        String.contains?(url, "/commits/") and String.contains?(url, "/pulls?") -> {:ok, []}
        String.contains?(url, "/commits?") -> {:ok, []}
        String.contains?(url, "/pulls?") -> {:ok, [stale_pull()]}
        true -> {:error, {:unexpected_url, url}}
      end
    end

    defp stale_pull do
      %{
        "number" => 21,
        "title" => "Merged months before this window",
        "body" => "",
        "html_url" => "https://github.com/a/r/pull/21",
        "merged_at" => "2026-01-04T09:00:00Z",
        "updated_at" => "2026-08-30T12:00:00Z",
        "merge_commit_sha" => nil,
        "base" => %{"ref" => "main"}
      }
    end
  end

  # A pull request merged seconds before the scan. GitHub computes the merge
  # commit asynchronously, so it is briefly absent on one that is in the window.
  defmodule FreshMergeClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") -> {:ok, %{"sha" => String.duplicate("f", 40)}}
        String.contains?(url, "/commits/") and String.contains?(url, "/pulls?") -> {:ok, []}
        String.contains?(url, "/commits?") -> {:ok, []}
        String.contains?(url, "/pulls?") -> {:ok, [fresh_pull()]}
        true -> {:error, {:unexpected_url, url}}
      end
    end

    defp fresh_pull do
      %{
        "number" => 1759,
        "title" => "Merged as the scan started",
        "body" => "",
        "html_url" => "https://github.com/a/r/pull/1759",
        "merged_at" => "2026-08-30T21:59:30Z",
        "updated_at" => "2026-08-30T21:59:30Z",
        "merge_commit_sha" => nil,
        "base" => %{"ref" => "main"}
      }
    end
  end

  defmodule MissingMergeFieldClient do
    def get_json(url) do
      send(Process.get(:daily_evidence_test_pid), {:missing_merge_get, url})

      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => String.duplicate("f", 40)}}

        String.contains?(url, "/commits?") ->
          {:ok, []}

        String.contains?(url, "/pulls?") ->
          {:ok, [pull_without_merge_sha()]}

        String.ends_with?(url, "/pulls/1760") ->
          Process.get(
            :missing_merge_detail,
            {:ok, Map.delete(pull_without_merge_sha(), "head")}
          )

        String.contains?(url, "/issues/1760/events?") ->
          Process.get(:missing_merge_events)

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp pull_without_merge_sha do
      Fixture.pull_request(1760, %{
        "head" => %{"sha" => Fixture.sha(99_999)},
        "merged_at" => "2026-08-30T14:15:00Z",
        "updated_at" => "2026-08-30T14:15:00Z"
      })
      |> Map.delete("merge_commit_sha")
    end
  end

  defmodule LargeFakeClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => Fixture.sha(999)}}

        String.contains?(url, "/commits/") and String.contains?(url, "/pulls?") ->
          {:ok, []}

        String.contains?(url, "/commits?") ->
          {:ok,
           Enum.map(101..140, fn number ->
             %{
               "sha" => Fixture.sha(number),
               "html_url" => "https://github.com/a/r/commit/#{Fixture.sha(number)}",
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
               "merge_commit_sha" => Fixture.sha(number),
               "base" => %{"ref" => "main"}
             }
           end)}

        true ->
          {:error, {:unexpected_url, url}}
      end
    end
  end

  defmodule MovingPullRequestClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => Fixture.sha(999)}}

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

    defp pull_request(number), do: Fixture.pull_request(number)

    defp unmerged_pull_request(number) do
      pull_request(number)
      |> Map.put("merged_at", nil)
    end
  end

  # Bodies that follow the repository's pull request convention and are far too
  # large to keep whole, so the manifest must choose what to give up.
  defmodule SectionedBodyClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => Fixture.sha(999)}}

        String.contains?(url, "/commits?") ->
          {:ok, []}

        String.contains?(url, "/pulls?") ->
          {:ok, Enum.map(1..40, &pull_request(1_700 + &1))}

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp pull_request(number), do: Fixture.pull_request(number, %{"body" => body(number)})

    defp body(number) do
      """
      #{String.duplicate("Prose before any heading, which a daily update can live without. ", 40)}

      ## Summary
      #{String.duplicate("Changed the #{number} thing. ", 12)}

      ## Validation
      #{String.duplicate("Recreated the #{number} reproduction and reran the suite. ", 6)}

      ## Retrospective
      - Untracked follow-up work: none.
      """
    end
  end

  # Descriptions long enough that keeping them whole does not fit, which is the
  # shape that used to fall straight to no bodies at all.
  defmodule LongBodyClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => Fixture.sha(999)}}

        String.contains?(url, "/commits?") ->
          {:ok, Process.get(:long_body_commits, [])}

        String.contains?(url, "/commits/") ->
          {:ok, []}

        String.contains?(url, "/pulls?") ->
          {:ok, Enum.map(1..Process.get(:long_body_count, 20), &pull_request(1_780 + &1))}

        true ->
          {:error, {:unexpected_url, url}}
      end
    end

    defp pull_request(number),
      do:
        Fixture.pull_request(number, %{
          "body" =>
            if(number == 1799,
              do: nil,
              else: Process.get(:long_body_plain) || body(number)
            )
        })

    defp body(number) do
      """
      #{Process.get(:long_body_preamble, "")}
      ## Summary
      #{String.duplicate("What #{number} changed, at length. ", 60)}

      ## Validation
      #{String.duplicate("How #{number} was checked, at length. ", 60)}

      ## Retrospective
      #{String.duplicate("What #{number} left behind, at length. ", 60)}
      """
    end
  end

  defmodule DisappearingPullRequestClient do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") ->
          {:ok, %{"sha" => Fixture.sha(999)}}

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

    defp pull_request(number), do: Fixture.pull_request(number)

    defp unmerged_pull_request(number), do: pull_request(number) |> Map.put("merged_at", nil)
  end

  defmodule MovingHeadClient do
    def get_json(url) do
      send(self(), {:capture_url, url})
      generation = div(Process.get(:head_reads, 0) + 1, 2)

      cond do
        String.ends_with?(url, "/commits/main") ->
          [response | rest] = Process.get(:head_responses)
          Process.put(:head_responses, rest)
          Process.put(:head_reads, Process.get(:head_reads, 0) + 1)
          response

        String.contains?(url, "/pulls?") and String.contains?(url, "/commits/") ->
          {:ok, []}

        String.contains?(url, "/pulls?") ->
          {:ok, [Fixture.pull_request(generation)]}

        String.contains?(url, "/commits?") ->
          sha = Fixture.sha(1_000 + generation)

          {:ok,
           [
             %{
               "sha" => sha,
               "html_url" => "https://github.com/a/r/commit/#{sha}",
               "commit" => %{
                 "message" => "Direct change",
                 "committer" => %{"date" => "2026-08-30T12:00:00Z"}
               }
             }
           ]}

        true ->
          raise "unexpected capture URL: #{url}"
      end
    end
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

  test "unchanged source head is checked after the complete evidence scan" do
    assert {:ok, evidence} = capture_heads([{:ok, %{"sha" => @head}}, {:ok, %{"sha" => @head}}])
    assert evidence["source_head_sha"] == @head
    assert Process.get(:head_reads) == 2
    urls = capture_urls([])
    assert List.first(urls) == List.last(urls)
    assert Enum.at(urls, -2) =~ "/commits/#{Fixture.sha(1_001)}/pulls?"
  end

  test "a changed source head retries the whole capture and discards prior PRs and commits" do
    assert {:ok, evidence} =
             capture_heads(
               Enum.map([@head, @next_day, @next_day, @next_day], &{:ok, %{"sha" => &1}})
             )

    assert Process.get(:head_reads) == 4
    assert evidence["source_head_sha"] == @next_day
    assert evidence["pull_request_numbers"] == [2]
    assert Enum.map(evidence["commits"], & &1["sha"]) == [Fixture.sha(2), Fixture.sha(1_002)]
    queries = capture_urls([]) |> Enum.filter(&String.contains?(&1, "/commits?"))
    assert length(queries) == 2
    assert hd(queries) =~ "sha=#{@head}"
    assert List.last(queries) =~ "sha=#{@next_day}"
  end

  test "source head instability exhausts a bounded capture retry budget" do
    responses =
      Enum.map([@head, @next_day, @head, @next_day, @head, @next_day], &{:ok, %{"sha" => &1}})

    assert {:error, :daily_digest_source_head_unstable} = capture_heads(responses)
    assert Process.get(:head_reads) == 6

    refute :daily_digest_source_head_unstable in PtcManager.MaintainerActions.terminal_daily_digest_evidence_errors()
  end

  test "failed or malformed second head observations never accept a manifest" do
    for {response, reason} <- [
          {{:error, :rate_limited}, :rate_limited},
          {{:ok, %{"sha" => "bad-sha"}}, :invalid_github_head_sha},
          {{:ok, %{}}, :unexpected_github_response}
        ] do
      assert {:error, ^reason} = capture_heads([{:ok, %{"sha" => @head}}, response])
      assert Process.get(:head_reads) == 2
    end
  end

  defp capture_heads(responses) do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MovingHeadClient)
    Process.put(:head_responses, responses)
    Process.put(:head_reads, 0)

    Evidence.fetch(
      %PtcManager.Operations.Repository{
        github_owner: "a",
        github_name: "r",
        default_branch: "main"
      },
      %DailyDigest{
        window_started_at: ~U[2026-08-29 22:00:00Z],
        window_ended_at: ~U[2026-08-30 22:00:00Z]
      }
    )
  end

  defp capture_urls(urls) do
    receive do
      {:capture_url, url} -> capture_urls([url | urls])
    after
      0 -> Enum.reverse(urls)
    end
  end

  # The scan reads up to three pages ordered by mutable updated_at, so it sees
  # pull requests merged long before the window. Validating one of those failed
  # the whole digest, and the error is terminal, so a single unhealthy row in
  # the repository's history stopped every future digest for that day.
  test "a pull request outside the window is skipped without validating it" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, StalePullClient)

    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["pull_request_numbers"] == []
    assert evidence["change_count"] == 0
  end

  # In the window the merge commit is evidence the digest cannot do without, so
  # it still stops. It must not stop permanently: GitHub fills the sha in within
  # seconds, and the next scheduled run would succeed.
  test "a pull request merged as the scan started is retryable, not terminal" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, FreshMergeClient)

    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:error, :github_pull_request_merge_pending} = Evidence.fetch(repository, digest)

    refute :github_pull_request_merge_pending in PtcManager.MaintainerActions.terminal_daily_digest_evidence_errors()
  end

  test "resolves an omitted list and detail merge SHA from the exact merged event" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MissingMergeFieldClient)
    merge_sha = Fixture.sha(1760)

    Process.put(
      :missing_merge_events,
      {:ok,
       [
         %{"event" => "closed", "commit_id" => nil, "created_at" => "2026-08-30T14:15:00Z"},
         %{
           "event" => "merged",
           "commit_id" => merge_sha,
           "created_at" => "2026-08-30T14:15:00Z"
         }
       ]}
    )

    assert {:ok, evidence} = Evidence.fetch(repository_fixture(), digest())
    assert [%{"merge_commit_sha" => ^merge_sha} = pull] = evidence["pull_requests"]
    assert pull["merge_commit_source"] == "issue_event.merged.commit_id"
    assert pull["head_sha"] == Fixture.sha(99_999)
    assert hd(evidence["commits"])["sha"] == merge_sha
    refute hd(evidence["commits"])["sha"] == pull["head_sha"]
    urls = missing_merge_urls([])
    assert Enum.any?(urls, &String.ends_with?(&1, "/pulls/1760"))
    assert Enum.any?(urls, &String.contains?(&1, "/issues/1760/events?"))
  end

  test "treats unavailable omitted merge identity as terminal instead of merge-pending" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MissingMergeFieldClient)
    Process.put(:missing_merge_events, {:ok, []})

    assert {:error, :github_pull_request_merge_identity_unavailable} =
             Evidence.fetch(repository_fixture(), digest())

    assert :github_pull_request_merge_identity_unavailable in PtcManager.MaintainerActions.terminal_daily_digest_evidence_errors()
  end

  test "keeps merge identity transport failures retryable" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MissingMergeFieldClient)
    Process.put(:missing_merge_events, {:error, {:github_transport_error, :timeout}})

    assert {:error, {:github_transport_error, :timeout}} =
             Evidence.fetch(repository_fixture(), digest())
  end

  test "maps permanent detail and event endpoint failures to a terminal identity error" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MissingMergeFieldClient)

    for {detail, events} <- [
          {{:error, {:github_http_error, 404, "Not Found", nil}}, nil},
          {nil, {:error, {:github_http_error, 422, "Validation Failed", nil}}}
        ] do
      if detail,
        do: Process.put(:missing_merge_detail, detail),
        else: Process.delete(:missing_merge_detail)

      if events,
        do: Process.put(:missing_merge_events, events),
        else: Process.delete(:missing_merge_events)

      assert {:error, :github_pull_request_merge_identity_unavailable} =
               Evidence.fetch(repository_fixture(), digest())
    end
  end

  test "keeps server and rate-limit endpoint failures retryable" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MissingMergeFieldClient)

    for reason <- [
          {:github_http_error, 503, "Unavailable", nil},
          {:github_http_error, 403, "API rate limit exceeded", nil},
          {:github_http_error, 403, "Forbidden", 30_000}
        ] do
      Process.delete(:missing_merge_detail)
      Process.put(:missing_merge_events, {:error, reason})
      assert {:error, ^reason} = Evidence.fetch(repository_fixture(), digest())
    end
  end

  test "rejects malformed or mismatched merged events without using the PR head" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, MissingMergeFieldClient)

    for event <- [
          "not-an-event",
          %{
            "event" => "merged",
            "commit_id" => "not-a-sha",
            "created_at" => "2026-08-30T14:15:00Z"
          },
          %{
            "event" => "merged",
            "commit_id" => Fixture.sha(1760),
            "created_at" => "2026-08-30T14:15:01Z"
          }
        ] do
      Process.put(:missing_merge_events, {:ok, [event]})

      assert {:error, :unexpected_github_pull_request} =
               Evidence.fetch(repository_fixture(), digest())
    end
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

  defp digest do
    %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }
  end

  defp missing_merge_urls(urls) do
    receive do
      {:missing_merge_get, url} -> missing_merge_urls([url | urls])
    after
      0 -> Enum.reverse(urls)
    end
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
    assert Enum.all?(evidence["pull_requests"], &(byte_size(&1["body"]["preamble"]) <= 400))
    assert Enum.all?(evidence["pull_requests"], &(&1["body_coverage"] == "shortened"))
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

  test "gives up general prose before validation and retrospective material" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, SectionedBodyClient)
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["evidence_truncated"]
    assert evidence |> Jason.encode!() |> byte_size() <= 60_000

    bodies = Enum.map(evidence["pull_requests"], & &1["body"])

    assert Enum.all?(bodies, &(&1["summary"] =~ "Changed the"))
    assert Enum.all?(bodies, &(&1["validation"] =~ "reran the suite"))
    assert Enum.all?(bodies, &(&1["retrospective"] =~ "Untracked follow-up work"))

    # The prose before the headings is what went; the summary stays, because a
    # daily update cannot say what changed without it.
    assert Enum.all?(bodies, &Map.has_key?(&1, "summary"))
    refute Enum.any?(bodies, &Map.has_key?(&1, "preamble"))
    assert Enum.all?(evidence["pull_requests"], &(&1["body_coverage"] == "priority"))
  end

  test "a long day keeps something about every change rather than nothing about all" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, LongBodyClient)
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence |> Jason.encode!() |> byte_size() <= 60_000

    described =
      Enum.reject(evidence["pull_requests"], &(&1["body_coverage"] == "none_written"))

    # The flat 600-character slice this replaced kept prose for every pull
    # request on a day like this. Falling straight from whole bodies to none
    # would be a regression, so the ladder shortens first.
    assert length(described) == 19
    assert Enum.all?(described, &(&1["body"]["summary"] != nil))
    assert Enum.all?(described, &(&1["body_coverage"] == "shortened"))
  end

  test "a pull request with no description is not reported as one we dropped" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, LongBodyClient)
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)

    empty = Enum.find(evidence["pull_requests"], &(&1["number"] == 1799))
    assert empty["body_coverage"] == "none_written"
    refute Map.has_key?(empty, "body")
  end

  test "a busy day drops preambles before giving up shortened priority sections" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, LongBodyClient)
    Process.put(:long_body_preamble, String.duplicate("Optional introductory prose. ", 30))
    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    for {count, coverage} <- [{30, "shortened_priority"}, {40, "primary"}, {50, "primary"}] do
      Process.put(:long_body_count, count)
      assert {:ok, evidence} = Evidence.fetch(repository, digest)
      assert evidence |> Jason.encode!() |> byte_size() <= 60_000
      described = Enum.reject(evidence["pull_requests"], &(&1["body_coverage"] == "none_written"))
      assert length(described) == count - 1
      assert Enum.all?(described, &(&1["body"]["summary"] != nil))
      assert Enum.all?(described, &(&1["body_coverage"] == coverage))
    end
  end

  test "compaction preserves plain descriptions with a busy direct-commit feed" do
    Application.put_env(:ptc_manager, :daily_digest_github_client, LongBodyClient)
    Process.put(:long_body_count, 50)
    Process.put(:long_body_plain, String.duplicate("Useful description of what changed. ", 30))

    Process.put(
      :long_body_commits,
      Enum.map(1..20, fn number ->
        %{
          "sha" => Fixture.sha(number),
          "html_url" => "https://github.com/a/r/commit/#{Fixture.sha(number)}",
          "commit" => %{
            "message" => String.duplicate("Direct change. ", 15),
            "committer" => %{"date" => "2026-08-30T12:00:00Z"}
          }
        }
      end)
    )

    repository = repository_fixture(%{github_owner: "a", github_name: "r"})

    digest = %DailyDigest{
      window_started_at: ~U[2026-08-29 22:00:00Z],
      window_ended_at: ~U[2026-08-30 22:00:00Z]
    }

    assert {:ok, evidence} = Evidence.fetch(repository, digest)
    assert evidence["evidence_truncated"]
    assert evidence |> Jason.encode!() |> byte_size() <= 60_000
    described = Enum.reject(evidence["pull_requests"], &(&1["body_coverage"] == "none_written"))
    assert Enum.all?(described, &(&1["body"]["preamble"] != nil))
  end
end
