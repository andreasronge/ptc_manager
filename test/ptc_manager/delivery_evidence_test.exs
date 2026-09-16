defmodule PtcManager.DeliveryEvidenceTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.{DeliveryEvidence, DeliveryEvent, Operations}
  alias PtcManager.Operations.{PrPublication, AuditEvent, ResourceOperation}
  alias PtcManager.Reviews.Round

  @start ~U[2026-09-01 00:00:00.000000Z]
  @merge ~U[2026-09-01 12:00:00.000000Z]
  @finish ~U[2026-09-02 00:00:00.000000Z]
  @window %{started_at: @start, ended_at: @finish}

  defmodule NoGitHub do
    def get_json(_), do: raise("projection must not query GitHub")
  end

  defmodule CapturedGitHub do
    def get_json(url) do
      cond do
        String.ends_with?(url, "/commits/main") -> {:ok, %{"sha" => String.duplicate("f", 40)}}
        String.contains?(url, "/pulls?") -> {:ok, [Process.get(:captured_pull)]}
        String.contains?(url, "/commits?") -> {:ok, []}
        true -> raise "unexpected GitHub request"
      end
    end
  end

  setup do
    old = Application.get_env(:ptc_manager, :daily_digest_github_client)
    Application.put_env(:ptc_manager, :daily_digest_github_client, NoGitHub)

    on_exit(fn ->
      if old,
        do: Application.put_env(:ptc_manager, :daily_digest_github_client, old),
        else: Application.delete_env(:ptc_manager, :daily_digest_github_client)
    end)

    %{repository: repository_fixture()}
  end

  test "quiet days are complete measured zero, and historical PRs have unavailable enrichment", %{
    repository: repository
  } do
    assert {:ok, empty} = build(repository, [])
    assert empty["pull_requests"]["coverage"] == "complete"
    assert empty["pull_requests"]["data"] == []
    assert empty["direct_commits"]["data"] == []

    assert {:ok, evidence} = build(repository, [pull(repository)])
    entry = first_pull(evidence)
    assert entry["publication"]["coverage"] == "unavailable"
    assert entry["attempts"]["coverage"] == "unavailable"
    assert entry["attempts"]["data"] == []
    assert entry["health"]["data"]["review_round_count"] == nil
    assert entry["completion"]["trust"] == "reported"
    assert entry["completion"]["binding"] == "unavailable"
    assert entry["github"]["data"]["head_sha"] == nil
  end

  test "enriches only exact repository PR identity and keeps all heads distinct", %{
    repository: repository
  } do
    job = job(repository)
    publication = publication(job, 7)
    other = repository_fixture()
    other_job = job(other)
    publication(other_job, 7)

    assert {:ok, evidence} = build(repository, [pull(repository, %{"head_sha" => sha("e")})])
    entry = first_pull(evidence)
    assert entry["publication"]["data"]["id"] == publication.id
    [attempt] = entry["attempts"]["data"]
    assert attempt["job_id"] == job.id

    assert attempt["heads"] == %{
             "implementation" => sha("a"),
             "reviewed" => sha("b"),
             "published" => sha("c")
           }

    assert entry["github"]["data"]["head_sha"] == sha("e")
    assert entry["github"]["data"]["merge_commit_sha"] == sha("d")
    assert attempt["validation"]["head_sha"] == sha("a")
    assert attempt["validation"]["binding"] == "exact"
    refute Jason.encode!(evidence) =~ "secret-command-output"
  end

  test "includes failed earlier attempts and excludes post-merge attempts", %{
    repository: repository
  } do
    issue = issue_fixture(repository)
    earlier = job(repository, issue: issue, at: DateTime.add(@start, 1), state: "failed")
    producer = job(repository, issue: issue, at: DateTime.add(@start, 10))
    publication(producer, 7)
    later = job(repository, issue: issue, at: DateTime.add(@merge, 1))
    assert {:ok, evidence} = build(repository, [pull(repository)])
    attempts = first_pull(evidence)["attempts"]["data"]
    assert Enum.map(attempts, & &1["job_id"]) == [earlier.id, producer.id]

    assert Enum.map(attempts, & &1["inclusion_reason"]) == [
             "same_issue_created_before_merge",
             "producing_job"
           ]

    refute later.id in Enum.map(attempts, & &1["job_id"])
  end

  test "captured job creation distinguishes no managed operations from unknown history", %{
    repository: repository
  } do
    job = job(repository)
    publication(job, 7)
    assert {:ok, known} = build(repository, [pull(repository)])
    [attempt] = first_pull(known)["attempts"]["data"]
    assert attempt["managed_operations"]["coverage"] == "complete"
    assert attempt["managed_operations"]["data"] == []
    assert first_pull(known)["health"]["data"]["failed_managed_operation_count"] == 0

    Repo.delete_all(from e in DeliveryEvent, where: e.job_id == ^job.id)
    assert {:ok, historical} = build(repository, [pull(repository)])
    [attempt] = first_pull(historical)["attempts"]["data"]
    assert attempt["managed_operations"]["coverage"] == "partial"
    assert attempt["managed_operations"]["data"] == []
    assert first_pull(historical)["health"]["data"]["failed_managed_operation_count"] == nil
  end

  test "review prose is reported and lifecycle citations retain their table namespace", %{
    repository: repository
  } do
    job = job(repository)
    publication(job, 7)

    round =
      Repo.insert!(%Round{
        job_id: job.id,
        fencing_token: 0,
        generation: 0,
        number: 1,
        request_id: "review",
        state: "completed",
        head_sha: sha("b"),
        base_sha: sha("f"),
        diff_digest: String.duplicate("a", 64),
        input: %{"secret" => "private-prompt"},
        result: %{
          "summary" => "A useful review",
          "findings" => [%{"severity" => "low", "description" => "Check the edge case"}]
        },
        expires_at: @finish
      })

    audit =
      Repo.insert!(%AuditEvent{
        actor: "coordinator",
        action: "job.note",
        target_type: "job",
        target_id: job.id,
        details: %{"secret" => "private-audit-detail"}
      })

    assert {:ok, evidence} = build(repository, [pull(repository)])
    [attempt] = first_pull(evidence)["attempts"]["data"]
    [review] = attempt["reviews"]["data"]
    assert review["result"]["trust"] == "reported"
    assert review["result"]["head_sha"] == sha("b")
    assert review["result"]["source_ids"] == [%{"type" => "review_rounds", "id" => round.id}]
    assert %{"type" => "audit_events", "id" => audit.id} in attempt["audits"]["source_ids"]
    assert Enum.all?(attempt["lifecycle"]["data"], &(&1["source"]["type"] == "delivery_events"))
    refute Jason.encode!(evidence) =~ "private-prompt"
    refute Jason.encode!(evidence) =~ "private-audit-detail"
  end

  test "complete audits include publication-targeted records", %{repository: repository} do
    job = job(repository)
    publication = publication(job, 7)

    audit =
      Repo.insert!(%AuditEvent{
        actor: "coordinator",
        action: "pr_publication.status_synced",
        target_type: "pr_publication",
        target_id: publication.id,
        details: %{"secret" => "publication-private"}
      })

    assert {:ok, evidence} = build(repository, [pull(repository)])
    [attempt] = first_pull(evidence)["attempts"]["data"]
    assert %{"type" => "audit_events", "id" => audit.id} in attempt["audits"]["source_ids"]
    assert Enum.any?(attempt["audits"]["data"], &(&1["target_type"] == "pr_publication"))
    refute Jason.encode!(evidence) =~ "publication-private"
  end

  test "overlapping managed durations are sums of measurements, not elapsed or invented test results",
       %{repository: repository} do
    job = job(repository)
    publication(job, 7)
    worker = worker_fixture()

    run =
      Repo.insert!(%PtcManager.Operations.AgentRun{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "done",
        started_at: @start,
        last_heartbeat_at: @start
      })

    for {index, duration} <- [{1, 1_000}, {2, 1_000}, {3, nil}] do
      Repo.insert!(%ResourceOperation{
        worker_id: worker.id,
        repository_id: repository.id,
        job_id: job.id,
        agent_run_id: run.id,
        invocation_id: "operation-#{index}",
        label: "test",
        state: "failed",
        queued_at: @start,
        started_at: @start,
        finished_at: DateTime.add(@start, 1),
        run_duration_ms: duration,
        exit_status: 1,
        last_error: "do not expose arbitrary error bodies"
      })
    end

    assert {:ok, evidence} = build(repository, [pull(repository)])
    [attempt] = first_pull(evidence)["attempts"]["data"]
    operations = attempt["managed_operations"]["data"]
    assert Enum.all?(operations, &(&1["label"]["trust"] == "reported"))
    assert Enum.at(operations, 2)["run_duration_ms"] == nil
    assert first_pull(evidence)["health"]["data"]["managed_run_duration_ms"] == 2_000
    refute Jason.encode!(evidence) =~ "do not expose arbitrary"
  end

  test "readiness is measured only for the captured PR head and before merge", %{
    repository: repository
  } do
    job = job(repository, state: "working")

    publication(job, 7, %{
      remote_head_sha: sha("e"),
      draft: false,
      checks_state: "success",
      mergeability: "mergeable",
      pr_state: "open"
    })

    Repo.update_all(from(e in DeliveryEvent, where: e.job_id == ^job.id),
      set: [inserted_at: DateTime.add(@start, 300)]
    )

    assert {:ok, known} = build(repository, [pull(repository, %{"head_sha" => sha("e")})])
    assert first_pull(known)["health"]["data"]["time_to_ready_ms"] == 300_000
    assert {:ok, missing} = build(repository, [pull(repository)])
    assert first_pull(missing)["health"]["data"]["time_to_ready_ms"] == nil
    assert {:ok, wrong} = build(repository, [pull(repository, %{"head_sha" => sha("f")})])
    assert first_pull(wrong)["health"]["data"]["time_to_ready_ms"] == nil
  end

  test "the existing GitHub selector supplies readiness head evidence", %{repository: repository} do
    job = job(repository, state: "working")

    publication(job, 7, %{
      remote_head_sha: sha("e"),
      draft: false,
      checks_state: "success",
      mergeability: "mergeable",
      pr_state: "open"
    })

    Repo.update_all(from(e in DeliveryEvent, where: e.job_id == ^job.id),
      set: [inserted_at: DateTime.add(@start, 300)]
    )

    raw =
      pull(repository)
      |> Map.merge(%{
        "body" => "## Summary\nUseful change",
        "base" => %{"ref" => "main"},
        "head" => %{"sha" => sha("e")},
        "updated_at" => DateTime.to_iso8601(@merge)
      })

    Process.put(:captured_pull, raw)
    Application.put_env(:ptc_manager, :daily_digest_github_client, CapturedGitHub)

    digest = %PtcManager.DailyDigests.DailyDigest{
      window_started_at: @start,
      window_ended_at: @finish
    }

    assert {:ok, selection} = PtcManager.DailyDigests.Evidence.fetch(repository, digest)
    Application.put_env(:ptc_manager, :daily_digest_github_client, NoGitHub)

    assert {:ok, evidence} =
             DeliveryEvidence.build(repository, @window, selection, observed_at: @finish)

    assert first_pull(evidence)["health"]["data"]["time_to_ready_ms"] == 300_000
  end

  test "repository identity accepts canonical GitHub casing", %{repository: repository} do
    configured = %{
      repository
      | github_owner: String.upcase(repository.github_owner),
        github_name: String.upcase(repository.github_name)
    }

    assert {:ok, _} = build(configured, [pull(repository)])
  end

  test "identical snapshots encode identically without database writes", %{repository: repository} do
    job = job(repository)
    publication(job, 7)
    handler = "evidence-read-only-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ptc_manager, :repo, :query],
        &__MODULE__.capture_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, first} = build(repository, [pull(repository)])
    assert {:ok, second} = build(repository, [pull(repository)])
    assert Jason.encode!(first) == Jason.encode!(second)
    queries = drain_queries([])
    assert Enum.any?(queries, &String.starts_with?(&1, "SELECT"))

    refute Enum.any?(
             queries,
             &Regex.match?(~r/\A(?:INSERT|UPDATE|DELETE|CREATE|DROP|ALTER)\b/i, &1)
           )
  end

  test "enforces window, selection coherence, row bounds and encoded byte limits", %{
    repository: repository
  } do
    assert {:error, :invalid_observation_time} =
             DeliveryEvidence.build(repository, @window, manifest([]), observed_at: @start)

    assert {:error, :selection_mismatch} =
             DeliveryEvidence.build(repository, @window, Map.put(manifest([]), "change_count", 1),
               observed_at: @finish
             )

    assert {:error, :change_outside_window} =
             build(repository, [pull(repository, %{"merged_at" => DateTime.to_iso8601(@finish)})])

    assert {:error, :encoded_byte_limit} = build(repository, [pull(repository)], max_bytes: 100)

    assert {:error, :invalid_body} =
             build(repository, [pull(repository, %{"body" => %{"summary" => 12}})])

    assert {:error, :invalid_labels} = build(repository, [pull(repository, %{"labels" => [12]})])
    job = job(repository)
    publication(job, 7)

    for number <- 1..101 do
      Repo.insert!(%AuditEvent{
        actor: "coordinator",
        action: "job.note",
        target_type: "job",
        target_id: job.id,
        details: %{"n" => number}
      })
    end

    assert {:error, :collection_limit} = build(repository, [pull(repository)])
  end

  test "a realistic busy GitHub-only day fits a bounded projection", %{repository: repository} do
    pulls =
      for number <- 1..50,
          do:
            pull(repository, %{
              "number" => number,
              "html_url" => "#{url(repository)}/pull/#{number}",
              "body" =>
                Map.new(
                  ~w(summary validation retrospective),
                  &{&1, String.duplicate("Details about the change. ", 16)}
                )
            })

    assert {:ok, evidence} = build(repository, pulls)
    assert byte_size(Jason.encode!(evidence)) <= 240_000
    assert length(evidence["pull_requests"]["data"]) == 50
  end

  test "direct commits remain separate and bounded with reported timestamp limitations", %{
    repository: repository
  } do
    commit = %{
      "sha" => sha("a"),
      "html_url" => "#{url(repository)}/commit/#{sha("a")}",
      "included_at" => DateTime.to_iso8601(@start),
      "included_by" => "committer_date_without_merged_pull_request",
      "message" => "Direct change",
      "author" => "author"
    }

    selection = manifest([]) |> Map.merge(%{"commits" => [commit], "change_count" => 1})

    assert {:ok, evidence} =
             DeliveryEvidence.build(repository, @window, selection, observed_at: @finish)

    assert evidence["pull_requests"]["data"] == []
    [direct] = evidence["direct_commits"]["data"]
    assert direct["binding"] == "exact"
    assert direct["data"]["selection_caveat"] == "committer_time_is_not_push_arrival_time"

    configured = %{
      repository
      | github_owner: String.upcase(repository.github_owner),
        github_name: String.upcase(repository.github_name)
    }

    assert {:ok, _} = DeliveryEvidence.build(configured, @window, selection, observed_at: @finish)

    wrong =
      put_in(selection, ["commits"], [
        Map.put(commit, "html_url", "https://github.com/other/repo/commit/#{sha("a")}")
      ])

    assert {:error, :wrong_repository} =
             DeliveryEvidence.build(repository, @window, wrong, observed_at: @finish)
  end

  def capture_query(_event, _measurements, metadata, pid),
    do: send(pid, {:evidence_query, metadata.query})

  defp drain_queries(acc) do
    receive do
      {:evidence_query, query} -> drain_queries([query | acc])
    after
      0 -> acc
    end
  end

  defp build(repository, pulls, opts \\ []),
    do:
      DeliveryEvidence.build(
        repository,
        @window,
        manifest(pulls),
        Keyword.put_new(opts, :observed_at, @finish)
      )

  defp first_pull(evidence), do: hd(evidence["pull_requests"]["data"])
  defp sha(character), do: String.duplicate(character, 40)

  defp url(repository),
    do: "https://github.com/#{repository.github_owner}/#{repository.github_name}"

  defp pull(repository, attrs \\ %{}) do
    Map.merge(
      %{
        "number" => 7,
        "html_url" => "#{url(repository)}/pull/7",
        "title" => "Delivered improvement",
        "base_ref" => "main",
        "merge_commit_sha" => sha("d"),
        "merged_at" => DateTime.to_iso8601(@merge),
        "body" => %{"summary" => "A useful change", "validation" => "A reported check"},
        "body_coverage" => "complete"
      },
      attrs
    )
  end

  defp manifest(pulls) do
    %{
      "source_head_sha" => sha("f"),
      "pull_requests" => pulls,
      "pull_request_numbers" => Enum.map(pulls, & &1["number"]) |> Enum.sort(),
      "change_count" => length(pulls),
      "commits" =>
        Enum.map(pulls, fn pull ->
          %{
            "included_by" => "pull_request_merged_at",
            "pull_request_number" => pull["number"],
            "sha" => pull["merge_commit_sha"],
            "included_at" => pull["merged_at"]
          }
        end)
    }
  end

  defp job(repository, opts \\ []) do
    issue = Keyword.get_lazy(opts, :issue, fn -> issue_fixture(repository) end)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 2, "small")

    Repo.update_all(from(a in PtcManager.Operations.Approval, where: a.id == ^job.approval_id),
      set: [approved_at: @start]
    )

    job
    |> change(%{
      state: Keyword.get(opts, :state, "done"),
      inserted_at: Keyword.get(opts, :at, @start),
      result_head_sha: sha("a"),
      reviewed_head_sha: sha("b"),
      pre_publication_status: "passed",
      pre_publication_verified_sha: sha("a"),
      pre_publication_output: "secret-command-output"
    })
    |> Repo.update!()
  end

  defp publication(job, number, attrs \\ %{}) do
    Repo.insert!(
      PrPublication.changeset(
        %PrPublication{},
        Map.merge(
          %{
            job_id: job.id,
            repository_id: job.repository_id,
            pr_number: number,
            state: "published",
            idempotency_key:
              :crypto.hash(:sha256, "pub-#{job.id}") |> Base.encode16(case: :lower),
            fencing_token: 0,
            branch_name: "job-#{job.id}",
            head_sha: sha("c"),
            base_sha: sha("f"),
            diff_digest: String.duplicate("a", 64),
            published_at: @merge
          },
          attrs
        )
      )
    )
  end
end
