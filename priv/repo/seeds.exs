alias PtcManager.Operations
alias PtcManager.Operations.Repository
alias PtcManager.Repo

if Repo.aggregate(Repository, :count) == 0 do
  now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

  {:ok, repository} =
    Operations.create_repository(%{
      github_owner: "andreasronge",
      github_name: "ptc_runner",
      default_branch: "main",
      local_path: System.get_env("PTC_REPOSITORY_PATH")
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
      capabilities: %{"herdr" => true, "codex" => true, "claude" => true},
      last_heartbeat_at: now
    })

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
      herdr_session: "implementer-demo"
    })

  IO.puts(
    "Seeded PtcManager demo data, including issue ##{unreviewed_issue.number} awaiting investigation."
  )
end
