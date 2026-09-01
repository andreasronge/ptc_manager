alias PtcManager.Operations
alias PtcManager.Operations.{Job, Repository, WorktreeAllocation}
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

  {:ok, _implementer_run} =
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

  IO.puts(
    "Seeded PtcManager demo data, including issue ##{unreviewed_issue.number} awaiting investigation."
  )
end
