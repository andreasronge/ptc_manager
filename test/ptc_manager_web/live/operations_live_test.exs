defmodule PtcManagerWeb.OperationsLiveTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.{CapacitySettings, MachineUsage, Operations}
  alias PtcManager.ResourceOperations
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

  test "tab paths drop blank parameters and keep the rest" do
    assert OperationsLive.tab_path(:index) == "/operations"
    assert OperationsLive.tab_path(:index, range: nil, agent: 7) == "/operations?agent=7"
    assert OperationsLive.tab_path(:agents, state: "failed") == "/operations/agents?state=failed"
    assert OperationsLive.range_path("24h") == "/operations"
    assert OperationsLive.range_path("7d") == "/operations?range=7d"
    assert OperationsLive.filter_path("all", false) == "/operations/agents"

    assert OperationsLive.filter_path("done", true) ==
             "/operations/agents?state=done&maintenance=1"
  end

  test "timeline runs are grouped by the day they started" do
    now = ~U[2026-09-02 15:00:00Z]

    runs = [
      %{id: 1, started_at: ~U[2026-09-02 14:00:00Z]},
      %{id: 2, started_at: ~U[2026-09-02 09:00:00Z]},
      %{id: 3, started_at: ~U[2026-09-01 23:00:00Z]},
      %{id: 4, started_at: ~U[2026-08-28 10:00:00Z]}
    ]

    assert [{"Today", [_, _]}, {"Yesterday", [_]}, {"Fri 28 Aug", [_]}] =
             OperationsLive.timeline_groups(runs, now)
  end

  describe "with a busy machine" do
    setup [:stub_transcript, :pin_capacity, :busy_machine]

    test "the Now tab shows capacity, the usage chart, running work, the queue, and workers",
         %{conn: conn} = context do
      {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/operations")

      assert html =~ "Capacity right now"
      assert has_element?(view, "#operations-tabs a[aria-current=page]", "Now")
      assert has_element?(view, "#metric-cpu")
      assert has_element?(view, "#metric-memory")
      assert has_element?(view, "#metric-application-memory", "PtcManager memory")
      assert has_element?(view, "#metric-disk")
      assert has_element?(view, "#metric-agents", "Herdr online")
      assert has_element?(view, "#light-agent-slots", "0/2")
      assert has_element?(view, "#heavy-agent-slots", "2/1")
      assert has_element?(view, "#operation-slots", "1/1")
      assert has_element?(view, "#light-agent-slots", "2 available")
      assert has_element?(view, "#heavy-agent-slots", "0 available")

      assert has_element?(view, "#machine-usage", "Machine usage")
      assert has_element?(view, "#machine-usage", "Occupied slots · capacity 4")
      assert has_element?(view, "#machine-usage a[data-range=\"24h\"][aria-current=true]")
      assert has_element?(view, "#machine-usage", "Heavy 1 · Light 2 · Operations 1")

      assert has_element?(view, "#running-now")
      assert has_element?(view, "#active-run-#{context.run.id}", "Add bounded result contracts")
      assert has_element?(view, "#resource-operation-#{context.resource_operation.id}", "test")

      assert has_element?(
               view,
               "#resource-operation-#{context.resource_operation.id}",
               "Operation slot 1"
             )

      assert html =~ "Herdr build one"

      assert has_element?(
               view,
               "#worker-recovery-#{context.recovering_worker.id}",
               "Recovery check 1 of 2"
             )

      assert has_element?(
               view,
               "#worker-recovery-#{context.recovering_worker.id}",
               "host restart"
             )

      assert has_element?(
               view,
               "#worker-recovery-#{context.recovering_worker.id}",
               "New work is paused"
             )

      assert has_element?(view, "#work-queue")
      assert has_element?(view, "#queued-action-#{context.priority_action.id}", "Merge priority")
      assert has_element?(view, "#queued-action-#{context.priority_action.id}", "Heavy work")
      assert has_element?(view, "#queued-action-#{context.planning_action.id}", "Heavy work")
      assert has_element?(view, "#queued-action-#{context.daily_action.id}", "Daily update")

      assert has_element?(
               view,
               "#queued-action-#{context.daily_action.id}",
               "github_pull_request_merge_pending"
             )

      assert has_element?(view, "#queued-job-#{context.queued_job.id}", "Implementation")
      assert has_element?(view, "#queued-job-#{context.queued_job.id}", "3 review passes")

      refute has_element?(view, "#agent-timeline")
      refute has_element?(view, "#workspace-setup-history")

      view |> element("#machine-usage a[data-range=\"7d\"]") |> render_click()
      assert_patch(view, ~p"/operations?range=7d")
      assert has_element?(view, "#machine-usage a[data-range=\"7d\"][aria-current=true]")
      assert has_element?(view, "#machine-usage", "Averages per hour")

      view |> element("#active-run-#{context.run.id} a") |> render_click()
      assert_patch(view, ~p"/operations?range=7d&agent=#{context.run.id}")
      assert has_element?(view, "#agent-detail-panel", "Read-only terminal")
      assert has_element?(view, "#agent-terminal-output", "Result: 169 passed")
      refute render(view) =~ "textarea"

      view |> element("#close-agent-detail") |> render_click()
      assert_patch(view, ~p"/operations?range=7d")
      refute has_element?(view, "#agent-detail-panel")

      view
      |> element("#queued-job-#{context.queued_job.id} button[phx-click=cancel_queued_job]")
      |> render_click()

      refute has_element?(view, "#queued-job-#{context.queued_job.id}")
      assert Repo.get!(Job, context.queued_job.id).state == "cancelled"

      view
      |> element(
        "#queued-action-#{context.daily_action.id} button[phx-click=cancel_queued_action]"
      )
      |> render_click()

      refute has_element?(view, "#queued-action-#{context.daily_action.id}")
      assert Repo.get!(AgentAction, context.daily_action.id).state == "cancelled"

      send(view.pid, :metrics_tick)

      assert render(view) =~
               "Agent sessions and expensive command process trees have separate limits"

      {:ok, sample} = MachineUsage.record_sample(%{sampled_at: DateTime.utc_now()})
      send(view.pid, {:machine_usage_sampled, sample})
      assert render(view) =~ "Machine usage"
    end

    test "the Agents tab lists runs by day, filters them, and opens the terminal",
         %{conn: conn} = context do
      {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/operations/agents")

      assert html =~ "Agent history"
      assert has_element?(view, "#operations-tabs a[aria-current=page]", "Agents")
      assert has_element?(view, "#agent-timeline section[aria-label=Today]")
      assert has_element?(view, "#timeline-run-#{context.run.id}", "Add bounded result contracts")
      assert has_element?(view, "#timeline-run-#{context.failed_run.id}", "failed")
      assert has_element?(view, "#timeline-run-#{context.planning_run.id}", "review_issue_9005")
      refute has_element?(view, "#timeline-run-#{context.maintenance_run.id}")
      refute has_element?(view, "#metric-cpu")
      refute has_element?(view, "#work-queue")

      # A blocked agent keeps a live heartbeat while its pull request stands
      # still, so the tab has to say a person is the thing it waits on.
      assert has_element?(
               view,
               "#attention-run-#{context.stalled_run.id}",
               "Waiting for a person"
             )

      assert has_element?(view, "#agents-needing-attention", "impl_j")
      assert has_element?(view, "#timeline-run-#{context.stalled_run.id}", "Waiting for a person")
      assert has_element?(view, "#timeline-run-#{context.run.id}", "Working")

      view |> element("#timeline-filters a[data-filter=failed]") |> render_click()
      assert_patch(view, ~p"/operations/agents?state=failed")
      assert has_element?(view, "#timeline-run-#{context.failed_run.id}")
      refute has_element?(view, "#timeline-run-#{context.run.id}")

      view |> element("#toggle-maintenance-runs") |> render_click()
      assert_patch(view, ~p"/operations/agents?state=failed&maintenance=1")
      refute has_element?(view, "#timeline-run-#{context.maintenance_run.id}")

      view |> element("#timeline-filters a[data-filter=all]") |> render_click()
      assert_patch(view, ~p"/operations/agents?maintenance=1")

      assert has_element?(
               view,
               "#timeline-run-#{context.maintenance_run.id}",
               "Repository maintenance"
             )

      view |> element("#timeline-run-#{context.run.id} a") |> render_click()
      assert_patch(view, ~p"/operations/agents?maintenance=1&agent=#{context.run.id}")
      assert has_element?(view, "#agent-detail-panel", "Read-only terminal")
      assert has_element?(view, "#agent-terminal-output", "Result: 169 passed")

      view |> element("#close-agent-detail") |> render_click()
      assert_patch(view, ~p"/operations/agents?maintenance=1")
      refute has_element?(view, "#agent-detail-panel")

      view |> element("#timeline-run-#{context.planning_run.id} a") |> render_click()
      assert has_element?(view, "#agent-workspace-setup", "scripts/ptc/bootstrap")
      assert has_element?(view, "#agent-workspace-setup", "Warm cache")
      assert has_element?(view, "#agent-workspace-setup", "Dependencies 1.9s")
      assert has_element?(view, "#agent-workspace-setup-output", "review setup ready")
    end

    test "the Performance tab shows expensive-operation statistics and workspace preparation",
         %{conn: conn} = context do
      {:ok, view, html} = conn |> authenticated_conn() |> live(~p"/operations/performance")

      assert html =~ "Performance"
      assert has_element?(view, "#operations-tabs a[aria-current=page]", "Performance")
      assert has_element?(view, "#resource-operations", "Expensive operations")
      assert has_element?(view, "#operation-stat-count")
      assert has_element?(view, "#recent-resource-operations", "Recent operations")
      assert has_element?(view, "#workspace-setup-history")

      assert has_element?(
               view,
               "#workspace-setup-#{context.setup_allocation.id}",
               "scripts/ptc/setup-worktree"
             )

      assert has_element?(
               view,
               "#workspace-setup-#{context.setup_allocation.id}",
               "Worktree 1.4s"
             )

      assert has_element?(view, "#workspace-setup-#{context.setup_allocation.id}", "Setup 3m 43s")
      assert has_element?(view, "#workspace-setup-#{context.setup_allocation.id}", "Warm cache")

      assert has_element?(
               view,
               "#workspace-setup-#{context.setup_allocation.id}",
               "Dependencies 4.5s"
             )

      assert has_element?(
               view,
               "#workspace-setup-output-#{context.setup_allocation.id}[phx-update=ignore]"
             )

      refute has_element?(view, "#agent-timeline")
      refute has_element?(view, "#metric-cpu")
    end

    test "an unknown agent id shows a flash instead of crashing", %{conn: conn} do
      {:ok, view, _html} = conn |> authenticated_conn() |> live(~p"/operations?agent=999999")

      refute has_element?(view, "#agent-detail-panel")
      assert render(view) =~ "That agent run is no longer available."
    end
  end

  test "queue labels use resource class instead of queue lane" do
    assert OperationsLive.queued_action_lane_label(%{
             automation_definition_version: %{resource_class: "light"}
           }) == "Light work"

    assert OperationsLive.queued_action_lane_label(%{
             automation_definition_version: %{resource_class: "heavy"}
           }) == "Heavy work"
  end

  defp stub_transcript(_context) do
    previous_reader = Application.get_env(:ptc_manager, :herdr_transcript_reader)
    Application.put_env(:ptc_manager, :herdr_transcript_reader, FakeTranscript)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :herdr_transcript_reader, previous_reader)
    end)

    :ok
  end

  defp pin_capacity(_context) do
    original_capacity = CapacitySettings.current()

    {:ok, _setting} =
      CapacitySettings.update(%{
        light_agent_capacity: 2,
        heavy_agent_capacity: 1,
        operation_capacity: 1
      })

    on_exit(fn ->
      CapacitySettings.update(%{
        light_agent_capacity: original_capacity.light_agent_capacity,
        heavy_agent_capacity: original_capacity.heavy_agent_capacity,
        operation_capacity: original_capacity.operation_capacity
      })
    end)

    :ok
  end

  defp busy_machine(_context) do
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
        workspace_setup_output: "Dependencies ready\n",
        workspace_setup_cache_state: "hit",
        workspace_setup_phase_durations: %{
          "cache_restore_ms" => 1_200,
          "dependencies_ms" => 4_500,
          "asset_tools_ms" => 800
        }
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

    {:ok, _resource_operation} =
      ResourceOperations.request(%{
        worker_id: worker.id,
        repository_id: repository.id,
        job_id: job.id,
        agent_run_id: run.id,
        invocation_id: "operations-live-test",
        label: "test",
        priority: 20,
        state: "queued"
      })

    {:ok, resource_operation} = ResourceOperations.claim_next(worker.id)

    {:ok, resource_operation} =
      ResourceOperations.mark_running(resource_operation.id, resource_operation.attempt_token)

    priority_action =
      queued_action!(repository, "repair_and_merge_pr", "pull_request", 9_004, now)

    planning_action =
      queued_action!(
        repository,
        "review_issue",
        "issue",
        9_005,
        DateTime.add(now, 1, :microsecond)
      )

    daily_action =
      queued_action!(
        repository,
        "daily_digest",
        "daily_digest",
        9_006,
        DateTime.add(now, 2, :microsecond)
      )

    daily_action =
      daily_action
      |> AgentAction.changeset(%{
        last_error: "Planning source snapshot pending: :github_pull_request_merge_pending"
      })
      |> Repo.update!()

    {:ok, planning_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: planning_action.id,
        role: "manager",
        state: "working",
        agent_name: "review_issue_9005",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        workspace_setup_state: "passed",
        workspace_setup_script: "scripts/ptc/bootstrap",
        workspace_setup_source_sha: String.duplicate("b", 40),
        workspace_setup_started_at: DateTime.add(now, -63, :second),
        workspace_setup_ended_at: DateTime.add(now, -60, :second),
        workspace_setup_duration_ms: 3_000,
        workspace_setup_exit_status: 0,
        workspace_setup_output: "review setup ready\n",
        workspace_setup_cache_state: "hit",
        workspace_setup_phase_durations: %{"dependencies_ms" => 1_900}
      })

    {:ok, failed_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: priority_action.id,
        role: "manager",
        state: "failed",
        agent_name: "repair_9004",
        started_at: DateTime.add(now, -3_600, :second),
        last_heartbeat_at: DateTime.add(now, -3_000, :second),
        ended_at: DateTime.add(now, -3_000, :second)
      })

    {:ok, stalled_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "blocked",
        agent_name: "impl_j#{job.id}_f1",
        fencing_token: 1,
        started_at: DateTime.add(now, -100_000, :second),
        state_changed_at: DateTime.add(now, -100_000, :second),
        last_heartbeat_at: now
      })

    {:ok, maintenance_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "manager",
        state: "done",
        agent_name: "deploy_canary_1",
        started_at: DateTime.add(now, -7_200, :second),
        last_heartbeat_at: DateTime.add(now, -7_100, :second),
        ended_at: DateTime.add(now, -7_100, :second)
      })

    {:ok, _sample} =
      MachineUsage.record_sample(%{
        sampled_at: DateTime.add(now, -90, :second),
        cpu_percent: 40.0,
        memory_percent: 55.0,
        disk_percent: 20.0,
        load_one: 1.5,
        active_light_agents: 2,
        active_heavy_agents: 1,
        active_operations: 1
      })

    %{
      run: run,
      planning_run: planning_run,
      failed_run: failed_run,
      stalled_run: stalled_run,
      maintenance_run: maintenance_run,
      queued_job: queued_job,
      resource_operation: resource_operation,
      recovering_worker: recovering_worker,
      setup_allocation: setup_allocation,
      priority_action: priority_action,
      planning_action: planning_action,
      daily_action: daily_action
    }
  end

  defp queued_action!(repository, action_key, target_type, target_id, requested_at) do
    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: action_key,
      target_type: target_type,
      target_id: target_id,
      target_label:
        if(target_type == "daily_digest",
          do: "example/repo · 2026-08-30",
          else: "example/repo##{target_id}"
        ),
      prompt_version: 1,
      prompt: "Do the #{action_key} work",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "maintainer",
      state: "queued",
      attempt_count: 0,
      requested_at: requested_at
    })
    |> Repo.insert!()
  end

  defp authenticated_conn(conn),
    do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})
end
