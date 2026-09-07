defmodule PtcManager.DeliveryReportDemo do
  @moduledoc "Deterministic delivery evidence for the isolated demo database only."
  import Ecto.Query
  alias PtcManager.{Repo, Operations}

  alias PtcManager.Operations.{
    WorktreeAllocation,
    ResourceOperation,
    AuditEvent,
    PrPublication
  }

  def seed(issue, worker, now) do
    unless Application.get_env(:ptc_manager, :demo_mode, false),
      do: raise("delivery demo requires demo mode")

    {:ok, job} = Operations.approve_issue(issue.id, "demo-maintainer", 3, "small")
    start = DateTime.add(now, -4_680, :second)

    job.approval_id
    |> then(&Repo.get!(PtcManager.Operations.Approval, &1))
    |> Ecto.Changeset.change(approved_at: start)
    |> Repo.update!()

    Repo.update_all(
      from(a in AuditEvent, where: a.target_type == "job" and a.target_id == ^job.id),
      set: [inserted_at: start]
    )

    head = String.duplicate("b", 40)
    base = String.duplicate("a", 40)
    digest = String.duplicate("c", 64)

    job =
      job
      |> Ecto.Changeset.change(%{
        inserted_at: start,
        state: "pr_open",
        fencing_token: 1,
        started_at: DateTime.add(start, 1080, :second),
        branch_name: "demo/delivery-report",
        review_state: "passed",
        reviewed_head_sha: head,
        result_head_sha: head,
        result_base_sha: base,
        result_diff_digest: digest,
        pre_publication_status: "passed",
        pre_publication_verified_sha: head,
        pre_publication_duration_ms: 134_000
      })
      |> Repo.update!()

    Repo.delete_all(from(e in PtcManager.DeliveryEvent, where: e.job_id == ^job.id))

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "done",
        started_at: job.started_at,
        ended_at: now,
        last_heartbeat_at: now,
        fencing_token: 1
      })

    Repo.insert!(
      WorktreeAllocation.changeset(%WorktreeAllocation{}, %{
        job_id: job.id,
        worker_id: worker.id,
        state: "awaiting_pr",
        last_used_at: now,
        worktree_created_duration_ms: 400,
        workspace_setup_duration_ms: 29_600,
        workspace_setup_state: "passed",
        workspace_setup_cache_state: "hit",
        workspace_setup_started_at: DateTime.add(job.started_at, 400, :millisecond),
        workspace_setup_ended_at: DateTime.add(job.started_at, 30, :second),
        workspace_setup_phase_durations: %{
          "cache_restore_ms" => 8000,
          "dependencies_ms" => 16000,
          "asset_tools_ms" => 2000,
          "cache_publish_ms" => 3000
        },
        workspace_setup_output: "Demo setup completed successfully."
      })
    )

    for {number, state} <- [{1, "completed"}, {2, "failed"}, {3, "completed"}] do
      at = DateTime.add(start, 2400 + number * 300, :second)

      settings =
        Map.put(
          job.execution_settings,
          "reviewer_model",
          if(number == 1, do: "gpt-5.6-sol", else: "gpt-6-astra")
        )

      Repo.insert!(
        PtcManager.Reviews.Round.changeset(%PtcManager.Reviews.Round{}, %{
          job_id: job.id,
          fencing_token: 1,
          generation: 0,
          number: number,
          request_id: "demo-review-#{number}",
          state: state,
          head_sha: if(number == 1, do: String.duplicate("d", 40), else: head),
          base_sha: base,
          diff_digest: digest,
          expires_at: DateTime.add(at, 900, :second),
          input: %{
            "settings" => settings,
            "handoff" =>
              if(number == 1,
                do: "Implemented bounded retry evidence and ran focused tests.",
                else:
                  "Scoped cleanup to the current run and added a concurrency regression test. See the commit diff for the change."
              )
          },
          error: if(state == "failed", do: "review_timeout: no assessment returned"),
          result:
            if(state == "completed",
              do: %{
                "summary" =>
                  if(number == 1,
                    do: "Cleanup can affect another run.",
                    else: "No unresolved actionable findings."
                  ),
                "findings" =>
                  if(number == 1,
                    do: [
                      %{
                        "severity" => "medium",
                        "description" => "Limit cleanup to files owned by this run."
                      }
                    ],
                    else: []
                  )
              }
            ),
          usage:
            if(state == "completed",
              do: %{
                "input_tokens" => 120_000,
                "cached_input_tokens" => 80_000,
                "output_tokens" => 4_000
              }
            )
        })
        |> Ecto.Changeset.change(inserted_at: at, updated_at: DateTime.add(at, 120, :second))
      )
    end

    for {label, index} <- Enum.with_index(~w(build test lint verify), 1) do
      duration = index * 20_000
      finish = DateTime.add(now, -index * 150, :second)

      Repo.insert!(
        ResourceOperation.changeset(%ResourceOperation{}, %{
          job_id: job.id,
          repository_id: job.repository_id,
          agent_run_id: run.id,
          worker_id: worker.id,
          invocation_id: "delivery-demo-#{index}",
          label: label,
          state: if(index == 2, do: "failed", else: "completed"),
          queued_at: DateTime.add(finish, -duration - 10_000, :millisecond),
          started_at: DateTime.add(finish, -duration, :millisecond),
          finished_at: finish,
          run_duration_ms: duration,
          wait_duration_ms: 10_000,
          exit_status: if(index == 2, do: 1, else: 0),
          peak_memory_bytes: index * 500_000_000,
          resource_metrics:
            if(index == 3,
              do: nil,
              else: %{
                "cpu_usage_usec" => duration * 2500,
                "allowed_cpus" => 8,
                "memory_limit_bytes" => 8_589_934_592,
                "cpu_throttled_usec" => 0,
                "oom_kills" => 0
              }
            )
        })
      )
    end

    for {offset, from, to} <- [
          {1080, "implementation_queue", "workspace_and_startup"},
          {1110, "workspace_and_startup", "working"},
          {2700, "working", "review"},
          {3300, "review", "maintainer_decision"},
          {3660, "maintainer_decision", "review"},
          {3900, "review", "working"}
        ] do
      Repo.insert!(%AuditEvent{
        actor: "coordinator",
        action: "job.phase_changed",
        target_type: "job",
        target_id: job.id,
        details: %{"from" => from, "to" => to},
        inserted_at: DateTime.add(start, offset, :second)
      })
    end

    Repo.insert!(%AuditEvent{
      actor: "demo-maintainer",
      action: "review.continued",
      target_type: "job",
      target_id: job.id,
      inserted_at: DateTime.add(start, 3600, :second),
      details: %{
        "settings" => Map.put(job.execution_settings, "reviewer_model", "gpt-6-astra"),
        "instructions" => "Retry the assessment; retain the committed fix."
      }
    })

    Repo.insert!(
      PrPublication.changeset(%PrPublication{}, %{
        job_id: job.id,
        state: "published",
        idempotency_key: String.duplicate("f", 64),
        fencing_token: 1,
        branch_name: job.branch_name,
        base_sha: base,
        head_sha: head,
        diff_digest: digest,
        attempt_count: 1,
        pr_number: 1319,
        pr_url: "https://github.com/andreasronge/ptc_runner/pull/1319",
        remote_head_sha: head,
        remote_base_sha: base,
        published_at: now,
        pr_state: "open",
        pr_checked_at: now,
        draft: false,
        checks_state: "success",
        mergeability: "mergeable",
        comment_count: 3,
        inline_comment_count: 2
      })
    )

    job
  end
end
