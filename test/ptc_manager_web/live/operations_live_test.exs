defmodule PtcManagerWeb.OperationsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, Job, WorktreeAllocation}
  alias PtcManager.Repo
  alias PtcManagerWeb.OperationsLive

  defmodule FakeTranscript do
    def read(_run), do: {:ok, "Running mix test\nResult: 169 passed"}
  end

  test "does not recommend another agent until every machine signal is available" do
    assert OperationsLive.capacity_tone(%{
             metrics: %{cpu_percent: nil, memory_percent: 20.0, disk_percent: 10.0},
             available_slots: 2
           }) == :unknown
  end

  test "completed runs explain the coarsely recorded bottleneck without guessing" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    timing =
      OperationsLive.phase_timing(%{
        started_at: DateTime.add(now, -600, :second),
        ended_at: now,
        agent_action: %{requested_at: DateTime.add(now, -660, :second)}
      })

    assert timing.label == "The agent session took most recorded time"
    assert timing.detail =~ "Before session 1m 0s · session 10m 0s"
    assert timing.detail =~ "waits for CI"
  end

  test "shows machine capacity, workers, and an agent task timeline", %{conn: conn} do
    previous_reader = Application.get_env(:ptc_manager, :herdr_transcript_reader)
    Application.put_env(:ptc_manager, :herdr_transcript_reader, FakeTranscript)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :herdr_transcript_reader, previous_reader)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository, %{title: "Add bounded result contracts"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")

    worker =
      worker_fixture(%{
        name: "Herdr build one",
        capabilities: %{"herdr" => true, "implementation_slots" => 2}
      })

    worker_fixture(%{
      name: "Old offline worker",
      status: "offline",
      capabilities: %{"herdr" => true, "implementation_slots" => 8}
    })

    recovering_worker =
      worker_fixture(%{
        name: "Restarting worker",
        status: "degraded",
        capabilities: %{"herdr" => true, "implementation_slots" => 4},
        worker_incarnation_id: "worker-boot-2",
        previous_worker_incarnation_id: "worker-boot-1",
        herdr_incarnation_id: "herdr-boot-2",
        previous_herdr_incarnation_id: "herdr-boot-1",
        snapshot_sequence: 1,
        healthy_snapshot_count: 1,
        restart_reason: "host restart",
        incarnation_changed_at: DateTime.utc_now()
      })

    job
    |> Job.changeset(%{state: "working", lease_owner: worker.worker_key})
    |> Repo.update!()

    queued_issue = issue_fixture(repository, %{title: "Queue the next bounded change"})
    proposal_fixture(queued_issue)
    {:ok, queued_job} = Operations.approve_issue(queued_issue.id, "maintainer", 3)

    setup_allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "attention",
        path: "/tmp/uncertain-operations-slot",
        last_used_at: DateTime.utc_now(),
        worktree_created_duration_ms: 1_400,
        workspace_setup_state: "passed",
        workspace_setup_script: "scripts/ptc/setup-worktree",
        workspace_setup_source_sha: String.duplicate("a", 40),
        workspace_setup_started_at: DateTime.add(DateTime.utc_now(), -224, :second),
        workspace_setup_ended_at: DateTime.utc_now(),
        workspace_setup_duration_ms: 223_000,
        workspace_setup_exit_status: 0,
        workspace_setup_output: "Dependencies ready\n"
      })
      |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "working",
        agent_name: "impl_j#{job.id}_f1",
        started_at: DateTime.add(now, -120, :second),
        last_heartbeat_at: now
      })

    priority_action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: 9_004,
        target_label: "example/repo#9004",
        prompt_version: 1,
        prompt: "Fix and merge the exact pull request",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "queued",
        attempt_count: 0,
        requested_at: now
      })
      |> Repo.insert!()

    planning_action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "review_issue",
        target_type: "issue",
        target_id: 9_005,
        target_label: "example/repo#9005",
        prompt_version: 1,
        prompt: "Review the issue",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "queued",
        attempt_count: 0,
        requested_at: DateTime.add(now, 1, :microsecond)
      })
      |> Repo.insert!()

    daily_action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "daily_digest",
        target_type: "daily_digest",
        target_id: 9_006,
        target_label: "example/repo · 2026-08-30",
        prompt_version: 1,
        prompt: "Summarize the previous day",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "scheduler",
        state: "queued",
        attempt_count: 0,
        requested_at: DateTime.add(now, 2, :microsecond)
      })
      |> Repo.insert!()

    {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/operations")

    assert html =~ "Capacity and agent history"
    assert has_element?(view, "#metric-cpu")
    assert has_element?(view, "#metric-memory")
    assert has_element?(view, "#metric-disk")
    assert has_element?(view, "#timeline-run-#{run.id}", "Add bounded result contracts")
    assert html =~ "Herdr build one"
    assert has_element?(view, "#worker-recovery-#{recovering_worker.id}", "Recovery check 1 of 2")
    assert has_element?(view, "#worker-recovery-#{recovering_worker.id}", "host restart")
    assert has_element?(view, "#worker-recovery-#{recovering_worker.id}", "New work is paused")
    assert has_element?(view, "#metric-agents", "1 / 2")
    assert has_element?(view, "#work-queue")
    assert has_element?(view, "#queued-action-#{priority_action.id}", "Merge priority")
    assert has_element?(view, "#queued-action-#{priority_action.id}", "Writer lane")
    assert has_element?(view, "#queued-action-#{planning_action.id}", "Planning lane")
    assert has_element?(view, "#queued-action-#{daily_action.id}", "Daily update")
    assert has_element?(view, "#queued-action-#{daily_action.id}", "Planning lane")
    assert has_element?(view, "#queued-job-#{queued_job.id}", "Implementation")
    assert has_element?(view, "#queued-job-#{queued_job.id}", "3 review passes")
    assert has_element?(view, "#workspace-setup-history")

    assert has_element?(
             view,
             "#workspace-setup-#{setup_allocation.id}",
             "scripts/ptc/setup-worktree"
           )

    assert has_element?(view, "#workspace-setup-#{setup_allocation.id}", "Worktree 1.4s")
    assert has_element?(view, "#workspace-setup-#{setup_allocation.id}", "Setup 3m 43s")
    assert has_element?(view, "#workspace-setup-#{setup_allocation.id}", "Dependencies ready")

    assert has_element?(
             view,
             "#workspace-setup-output-#{setup_allocation.id}[phx-update=ignore]"
           )

    view
    |> element("#timeline-run-#{run.id} a")
    |> render_click()

    assert_patch(view, ~p"/operations?agent=#{run.id}")
    assert has_element?(view, "#agent-detail-panel", "Read-only terminal")
    assert has_element?(view, "#agent-terminal-output", "Result: 169 passed")
    refute render(view) =~ "textarea"

    view |> element("#close-agent-detail") |> render_click()
    assert_patch(view, ~p"/operations")
    refute has_element?(view, "#agent-detail-panel")

    send(view.pid, :metrics_tick)
    assert render(view) =~ "configured slot(s) currently available"
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
