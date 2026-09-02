alias PtcManager.Operations
alias PtcManager.Operations.{Job, Repository, ResourceOperation, WorktreeAllocation}
alias PtcManager.Repo

if Repo.aggregate(Repository, :count) == 0 do
  now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
  demo_mode = Application.get_env(:ptc_manager, :demo_mode, false)

  {:ok, repository} =
    Operations.create_repository(%{
      github_owner: "andreasronge",
      github_name: "ptc_runner",
      default_branch: "main",
      local_path: if(demo_mode, do: nil, else: System.get_env("PTC_REPOSITORY_PATH")),
      required_pre_pr_reviews:
        if(demo_mode,
          do: 2,
          else: Application.get_env(:ptc_manager, :required_pre_pr_reviews_default, 2)
        )
    })

  issue_attrs = fn number, title, minutes_ago ->
    updated_at = DateTime.add(now, -minutes_ago, :minute)
    body_digest = Base.encode16(:crypto.hash(:sha256, "demo-body-#{number}"), case: :lower)

    %{
      repository_id: repository.id,
      number: number,
      title: title,
      html_url: "https://github.com/andreasronge/ptc_runner/issues/#{number}",
      body: "Demo issue body for local interface testing.",
      state: "open",
      workflow_label: "ptc:ready",
      dependencies_projected: true,
      github_assignment_projected: true,
      body_digest: body_digest,
      content_digest:
        Base.encode16(:crypto.hash(:sha256, "#{title}:#{body_digest}"), case: :lower),
      github_updated_at: updated_at
    }
  end

  {:ok, active_issue} =
    Operations.create_issue(
      issue_attrs.(1320, "Make remote tool failures easier to understand", 35)
    )

  {:ok, ready_issue} =
    Operations.create_issue(issue_attrs.(1318, "Add bounded retry evidence to run summaries", 95))

  {:ok, unreviewed_issue} =
    Operations.create_issue(
      issue_attrs.(1314, "Clarify the standalone install upgrade path", 180)
    )

  proposal_attrs = fn issue, summary, why, scope, risk, evidence ->
    %{
      issue_id: issue.id,
      source_updated_at: issue.github_updated_at,
      source_digest: issue.content_digest,
      proposal_digest:
        Base.encode16(:crypto.hash(:sha256, "#{issue.id}:#{summary}"), case: :lower),
      plain_summary: summary,
      why_it_matters: why,
      scope: scope,
      risk: risk,
      readiness: "ready",
      technical_evidence: evidence
    }
  end

  {:ok, _proposal} =
    Operations.create_proposal(
      proposal_attrs.(
        active_issue,
        "When a remote tool fails, users currently get too little information to know what to fix.",
        "Clear errors reduce failed agent runs and make support easier.",
        "medium",
        "medium",
        "The error envelope loses the bounded failure category before the viewer renders it. The change should preserve the category without exposing raw provider output."
      )
    )

  {:ok, _proposal} =
    Operations.create_proposal(
      proposal_attrs.(
        ready_issue,
        "Keep a small record of why a retry happened, so a maintainer can tell whether retrying helped.",
        "Today several retries can look like one slow run, which hides reliability problems.",
        "small",
        "low",
        "The trace already records attempt boundaries. The summary projection needs a bounded retry count and final reason, covered by trace contract tests."
      )
    )

  {:ok, active_job} = Operations.approve_issue(active_issue.id, "demo-maintainer")

  {:ok, worker} =
    Operations.create_worker(%{
      worker_key: "hetzner-primary",
      name: "Hetzner primary",
      status: "online",
      capabilities: %{
        "herdr" => true,
        "codex" => true,
        "claude" => true,
        "implementation_slots" =>
          if(demo_mode,
            do: 1,
            else: Application.get_env(:ptc_manager, :implementation_agent_capacity, 1)
          )
      },
      last_heartbeat_at: now
    })

  active_job =
    active_job
    |> Job.changeset(%{
      state: "working",
      fencing_token: 1,
      lease_owner: worker.worker_key,
      lease_expires_at: DateTime.add(now, 86_400, :second),
      started_at: now,
      branch_name: "ptc-manager/issue-1320-job-#{active_job.id}",
      publication_source: "broker"
    })
    |> Repo.update!()

  %WorktreeAllocation{}
  |> WorktreeAllocation.changeset(%{
    worker_id: worker.id,
    job_id: active_job.id,
    state: "active",
    path: Path.join(System.tmp_dir!(), "ptc-manager-demo-worktree"),
    herdr_workspace: "ptc-runner-1320",
    agent_kind: "demo",
    last_used_at: now,
    worktree_created_duration_ms: 1_420,
    workspace_setup_state: "passed",
    workspace_setup_script: "scripts/ptc/setup-worktree",
    workspace_setup_source_sha: String.duplicate("a", 40),
    workspace_setup_started_at: DateTime.add(now, -5, :minute),
    workspace_setup_ended_at: DateTime.add(now, -81, :second),
    workspace_setup_duration_ms: 218_000,
    workspace_setup_exit_status: 0,
    workspace_setup_output: "Dependencies and build tools are ready.\n",
    workspace_setup_cache_state: "hit",
    workspace_setup_phase_durations: %{
      "cache_restore_ms" => 2_100,
      "dependencies_ms" => 4_800,
      "asset_tools_ms" => 1_700
    }
  })
  |> Repo.insert!()

  {:ok, _manager_run} =
    Operations.create_agent_run(%{
      worker_id: worker.id,
      role: "manager",
      state: "working",
      status_text: "Reviewing the issue inbox and preparing private summaries.",
      started_at: DateTime.add(now, -23, :minute),
      last_heartbeat_at: DateTime.add(now, -4, :second),
      herdr_workspace: "ptc-manager",
      herdr_pane: "w1:p1",
      herdr_session: "manager-demo"
    })

  {:ok, implementer_run} =
    Operations.create_agent_run(%{
      worker_id: worker.id,
      job_id: active_job.id,
      role: "implementer",
      state: "working",
      status_text: "Tracing the remote error envelope and its viewer projection.",
      started_at: DateTime.add(now, -8, :minute),
      last_heartbeat_at: DateTime.add(now, -2, :second),
      herdr_workspace: "ptc-runner-1320",
      herdr_pane: "w2:p1",
      herdr_session: "implementer-demo",
      fencing_token: active_job.fencing_token
    })

  if demo_mode do
    Enum.with_index([18_000, 31_000, 44_000, 67_000, 96_000], 1)
    |> Enum.each(fn {duration_ms, index} ->
      finished_at = DateTime.add(now, -(index * 12), :minute)
      started_at = DateTime.add(finished_at, -duration_ms, :millisecond)
      queued_at = DateTime.add(started_at, -(index * 350), :millisecond)

      %ResourceOperation{}
      |> ResourceOperation.changeset(%{
        worker_id: worker.id,
        repository_id: repository.id,
        job_id: active_job.id,
        agent_run_id: implementer_run.id,
        invocation_id: "demo-completed-#{index}",
        label: Enum.at(~w(lint test build test verify), index - 1),
        priority: 300,
        state: "completed",
        slot_number: 1,
        fencing_token: index,
        queued_at: queued_at,
        started_at: started_at,
        last_heartbeat_at: finished_at,
        finished_at: finished_at,
        wait_duration_ms: index * 350,
        run_duration_ms: duration_ms,
        exit_status: 0,
        peak_memory_bytes: (350 + index * 180) * 1_048_576
      })
      |> Repo.insert!()
    end)

    {:ok, _operation} =
      PtcManager.ResourceOperations.request(
        %{
          worker_id: worker.id,
          repository_id: repository.id,
          job_id: active_job.id,
          agent_run_id: implementer_run.id,
          invocation_id: "demo-active-test",
          label: "test",
          priority: 300,
          state: "queued"
        },
        DateTime.add(now, -25, :second)
      )

    {:ok, operation} =
      PtcManager.ResourceOperations.claim_next(worker.id, DateTime.add(now, -20, :second))

    {:ok, _operation} =
      PtcManager.ResourceOperations.mark_running(
        operation.id,
        operation.attempt_token,
        %{wrapper_pid: 42_001, cgroup_path: "/demo/operation-test"},
        DateTime.add(now, -19, :second)
      )
  end

  if demo_mode do
    # Deterministic machine usage history so the Operations chart has a shape:
    # every 30 seconds for the last hour, every 5 minutes for the last day, and
    # hourly for the rest of the week.
    now_unix = DateTime.to_unix(now)
    week_start = now_unix - 7 * 86_400

    sample_times =
      Enum.uniq(
        Enum.map(0..119, &(now_unix - &1 * 30)) ++
          Enum.map(0..287, &(now_unix - &1 * 300)) ++
          Enum.map(0..167, &(now_unix - &1 * 3_600))
      )

    demo_samples =
      Enum.map(sample_times, fn unix ->
        heavy = if rem(unix, 7_200) < 4_500, do: 1, else: 0
        light = if rem(div(unix, 600), 3) == 0, do: 1, else: 0
        operations = if heavy == 1 and rem(div(unix, 300), 4) == 0, do: 1, else: 0
        jitter = :erlang.phash2(unix, 9) - 4
        cpu = 6 + heavy * 38 + light * 11 + operations * 28 + jitter

        %{
          sampled_at: DateTime.from_unix!(unix),
          cpu_percent: cpu / 1,
          memory_percent: (14 + heavy * 22 + operations * 16 + jitter / 2) / 1,
          disk_percent: 18.0 + (unix - week_start) / (7 * 86_400) * 1.5,
          load_one: cpu / 100 * 4,
          active_light_agents: light,
          active_heavy_agents: heavy,
          active_operations: operations
        }
      end)

    Repo.insert_all(PtcManager.MachineUsage.Sample, demo_samples)
  end

  IO.puts(
    "Seeded PtcManager demo data, including issue ##{unreviewed_issue.number} awaiting investigation."
  )
end
