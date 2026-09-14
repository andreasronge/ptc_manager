defmodule PtcManager.StallsTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.{ExecutionProfiles, Operations, Repo, Stalls}
  alias PtcManager.Collections.{Member, Run, Step, Structure}
  alias PtcManager.Operations.{AgentAction, Issue, Job, PrPublication, ResourceOperation}
  alias PtcManager.Reviews.Round

  @now ~U[2026-09-14 12:00:00.000000Z]

  setup do
    previous = Application.get_env(:ptc_manager, :operational_mode)
    Application.put_env(:ptc_manager, :operational_mode, :active)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ptc_manager, :operational_mode, previous),
        else: Application.delete_env(:ptc_manager, :operational_mode)
    end)

    %{repository: repository_fixture()}
  end

  describe "run_flapping/1" do
    test "a live run that paused and resumed twice within a minute is an alarm", %{
      repository: repository
    } do
      {run, _members} = run_fixture(repository, [11, 12])

      for {action, seconds_ago} <- [
            {"collection_run.paused", 300},
            {"collection_run.resumed", 290},
            {"collection_run.paused", 120},
            {"collection_run.resumed", 100}
          ] do
        audit!(run, action, seconds_ago)
      end

      assert [%{kind: :run_flapping, severity: :alarm, target_id: run_id, since: since}] =
               Stalls.run_flapping(@now)

      assert run_id == run.id
      assert since == seconds_ago(300)
    end

    test "pauses answered minutes later and completed runs are not flapping", %{
      repository: repository
    } do
      {run, _members} = run_fixture(repository, [11, 12])
      audit!(run, "collection_run.paused", 500)
      audit!(run, "collection_run.resumed", 300)
      audit!(run, "collection_run.paused", 200)
      audit!(run, "collection_run.resumed", 195)
      assert Stalls.run_flapping(@now) == []

      audit!(run, "collection_run.paused", 100)
      audit!(run, "collection_run.resumed", 95)
      assert [_flapping] = Stalls.run_flapping(@now)

      run |> Run.changeset(%{state: "completed"}) |> Repo.update!()
      assert Stalls.run_flapping(@now) == []
    end

    test "a resume answered by a pause on another member is not a flap", %{
      repository: repository
    } do
      {run, _members} = run_fixture(repository, [11, 12])
      audit!(run, "collection_run.paused", 400)
      audit!(run, "collection_run.resumed", 200)
      audit!(run, "collection_run.paused", 190)
      audit!(run, "collection_run.resumed", 100)
      assert Stalls.run_flapping(@now) == []
    end
  end

  describe "run_idle_complete/1" do
    test "every member delivered with no step for over a minute is an alarm", %{
      repository: repository
    } do
      {run, members} =
        run_fixture(repository, [21, 22], states: %{21 => "closed", 22 => "closed"})

      Enum.each(members, &close_completed!/1)
      age!(run, 600)

      assert [%{kind: :run_idle_complete, severity: :alarm, target_id: run_id, detail: detail}] =
               Stalls.run_idle_complete(@now)

      assert run_id == run.id
      assert detail =~ "delivered"

      step!(run, "closeout", "1", 30)
      assert Stalls.run_idle_complete(@now) == []
    end

    test "a close-out in flight or a restricted mode explains the missing step", %{
      repository: repository
    } do
      {run, members} =
        run_fixture(repository, [23, 24], states: %{23 => "closed", 24 => "closed"})

      Enum.each(members, &close_completed!/1)
      age!(run, 600)

      closeout =
        action!(repository, "collection_closeout", "issue", run.issue_id, "running", nil,
          actor: "system:collection"
        )

      assert Stalls.run_idle_complete(@now) == []

      closeout |> Ecto.Changeset.change(state: "done") |> Repo.update!()
      assert [_stall] = Stalls.run_idle_complete(@now)

      Application.put_env(:ptc_manager, :operational_mode, :maintenance)
      assert Stalls.run_idle_complete(@now) == []

      Application.put_env(:ptc_manager, :operational_mode, :active)
      {:ok, _repository} = Operations.set_repository_enabled(repository.id, false, "andreas")
      assert Stalls.run_idle_complete(@now) == []
    end

    test "a run with an open member is not idle complete", %{repository: repository} do
      {run, [first, _second]} =
        run_fixture(repository, [21, 22], states: %{21 => "closed"})

      close_completed!(first)
      age!(run, 600)
      assert Stalls.run_idle_complete(@now) == []
    end
  end

  describe "run_no_progress/1" do
    test "an active run with nothing live for longer than the threshold needs attention", %{
      repository: repository
    } do
      {run, [member | _]} = run_fixture(repository, [31, 32])
      age!(run, 7_200)

      assert [%{kind: :run_no_progress, severity: :attention, target_id: run_id, detail: detail}] =
               Stalls.run_no_progress(@now)

      assert run_id == run.id
      assert detail =~ "2 ready"

      {:ok, _job} = Operations.approve_issue_directly(member.id, "andreas")
      assert Stalls.run_no_progress(@now) == []
    end

    test "a recent step or a pending action counts as progress", %{repository: repository} do
      {run, [member | _]} = run_fixture(repository, [31, 32])
      age!(run, 7_200)
      step!(run, "admit", "#{member.id}", 60)
      assert Stalls.run_no_progress(@now) == []

      age!(run, 7_200)
      Repo.delete_all(Step)
      action!(repository, "prepare_issue", "issue", member.id, "queued", nil)
      assert Stalls.run_no_progress(@now) == []

      Repo.delete_all(AgentAction)
      assert [_stall] = Stalls.run_no_progress(@now)

      action!(repository, "collection_handoff", "issue", run.issue_id, "queued", nil,
        actor: "system:collection"
      )

      assert Stalls.run_no_progress(@now) == []
    end
  end

  describe "stop_unacknowledged/1" do
    test "a stop report nobody answered names the reason and the board", %{
      repository: repository
    } do
      issue = issue_fixture(repository, %{number: 41, workflow_label: "ptc:ready"})
      job = stopped_job!(issue, "ambiguous_requirement", "Which exit status?")

      assert [%{kind: :stop_unacknowledged, severity: :attention, target_id: job_id} = stall] =
               Stalls.stop_unacknowledged(@now)

      assert job_id == job.id
      assert stall.issue_id == issue.id
      assert stall.detail =~ "#41"
      assert stall.detail =~ "ambiguous"
      assert stall.detail =~ "Which exit status?"

      {:ok, _job} = Operations.acknowledge_job_stop(job.id, "andreas")
      assert Stalls.stop_unacknowledged(@now) == []
    end
  end

  describe "action_repeating_failure/1" do
    test "two consecutive failures with the same error on one target are an alarm", %{
      repository: repository
    } do
      issue = issue_fixture(repository, %{number: 51})
      action!(repository, "report_issue_blocker", "issue", issue.id, "failed", "schema: bad")

      latest =
        action!(repository, "report_issue_blocker", "issue", issue.id, "failed", "schema: bad")

      assert [%{kind: :action_repeating_failure, severity: :alarm, target_id: id, detail: detail}] =
               Stalls.action_repeating_failure(@now)

      assert id == latest.id
      assert detail =~ "schema: bad"
    end

    test "different errors, a success in between, or another target do not repeat", %{
      repository: repository
    } do
      issue = issue_fixture(repository, %{number: 51})
      other = issue_fixture(repository, %{number: 52})
      action!(repository, "report_issue_blocker", "issue", issue.id, "failed", "one")
      action!(repository, "report_issue_blocker", "issue", issue.id, "failed", "two")
      action!(repository, "report_issue_blocker", "issue", other.id, "failed", "two")
      assert Stalls.action_repeating_failure(@now) == []

      action!(repository, "prepare_issue", "issue", issue.id, "failed", "same")
      action!(repository, "prepare_issue", "issue", issue.id, "done", nil)
      action!(repository, "prepare_issue", "issue", issue.id, "failed", "same")
      assert Stalls.action_repeating_failure(@now) == []
    end
  end

  describe "review_snoozing/1" do
    test "a queued round in maintenance mode is an alarm", %{repository: repository} do
      issue = issue_fixture(repository, %{number: 61, workflow_label: "ptc:ready"})
      job = job!(issue, %{state: "working", review_state: "running"})
      round = round!(job, 1, "queued", nil)

      assert Stalls.review_snoozing(@now) == []

      Application.put_env(:ptc_manager, :operational_mode, :maintenance)
      assert Stalls.review_snoozing(@now) == [], "a fresh restriction is within the grace period"

      backdate!(Round, round.id, 600)

      assert [%{kind: :review_snoozing, severity: :alarm, target_id: job_id, detail: detail}] =
               Stalls.review_snoozing(@now)

      assert job_id == job.id
      assert detail =~ "maintenance mode"

      job |> Job.changeset(%{state: "failed"}) |> Repo.update!()
      assert Stalls.review_snoozing(@now) == []
    end

    test "a queued round runs in a drain, but a pending continuation does not", %{
      repository: repository
    } do
      issue = issue_fixture(repository, %{number: 62, workflow_label: "ptc:ready"})
      job = job!(issue, %{state: "working", review_state: "running"})
      round = round!(job, 1, "queued", nil)
      backdate!(Round, round.id, 600)
      Application.put_env(:ptc_manager, :operational_mode, :draining)
      assert Stalls.review_snoozing(@now) == []

      job |> Job.changeset(%{review_state: "resume_pending"}) |> Repo.update!()
      backdate!(Job, job.id, 600)
      assert [%{kind: :review_snoozing, detail: detail}] = Stalls.review_snoozing(@now)
      assert detail =~ "continuation"
    end
  end

  describe "review_repeated_finding/1" do
    test "the same finding in two consecutive rounds needs attention", %{repository: repository} do
      issue = issue_fixture(repository, %{number: 71, workflow_label: "ptc:ready"})
      job = job!(issue, %{state: "working", review_state: "paused"})
      round!(job, 1, "completed", ["Missing test for the empty case", "Typo in docs"])
      round!(job, 2, "completed", ["missing  test for the empty case"])

      assert [%{kind: :review_repeated_finding, severity: :attention, detail: detail}] =
               Stalls.review_repeated_finding(@now)

      assert detail =~ "round 2"
      assert detail =~ "round 1"
      assert detail =~ "empty case"
    end

    test "new findings each round, or a job without an open review, are not repeats", %{
      repository: repository
    } do
      issue = issue_fixture(repository, %{number: 72, workflow_label: "ptc:ready"})
      job = job!(issue, %{state: "working", review_state: "paused"})
      round!(job, 1, "completed", ["First"])
      round!(job, 2, "completed", ["Second"])
      assert Stalls.review_repeated_finding(@now) == []

      round!(job, 3, "completed", [{"low", "Second"}])

      assert Stalls.review_repeated_finding(@now) == [],
             "an advisory finding may travel to the pull request round after round"

      round!(job, 4, "completed", ["Third"])
      round!(job, 5, "completed", ["Third"])
      assert [_repeat] = Stalls.review_repeated_finding(@now)

      job |> Job.changeset(%{review_state: "passed"}) |> Repo.update!()
      assert Stalls.review_repeated_finding(@now) == []
    end
  end

  describe "operation_slot_orphaned/1" do
    test "a running operation with a slot and no heartbeat for minutes is an alarm", %{
      repository: repository
    } do
      operation = operation!(repository, "running", 600)

      assert [%{kind: :operation_slot_orphaned, severity: :alarm, target_id: id, detail: detail}] =
               Stalls.operation_slot_orphaned(@now)

      assert id == operation.id
      assert detail =~ "slot 1"
    end

    test "a heartbeat within the threshold or a released slot is healthy", %{
      repository: repository
    } do
      operation!(repository, "running", 30)
      operation!(repository, "completed", 600)
      marked = operation!(repository, "running", 20)
      assert Stalls.operation_slot_orphaned(@now) == []

      Repo.update_all(from(o in ResourceOperation, where: o.id == ^marked.id),
        set: [state: "recovery_pending", updated_at: seconds_ago(900)]
      )

      assert [%{target_id: id}] = Stalls.operation_slot_orphaned(@now)
      assert id == marked.id
    end
  end

  describe "dispatch_rejected/1" do
    test "a non-terminal rejection with no newer job needs attention", %{repository: repository} do
      issue = issue_fixture(repository, %{number: 81, workflow_label: "ptc:ready"})
      job = job!(issue, %{state: "cancelled", ended_at: seconds_ago(120)})
      audit_job!(job, "job.dispatch_rejected", %{"reason" => "worktree_changed"}, 120)

      assert [
               %{
                 kind: :dispatch_rejected,
                 severity: :attention,
                 target_id: job_id,
                 detail: detail
               }
             ] =
               Stalls.dispatch_rejected(@now)

      assert job_id == job.id
      assert detail =~ "worktree_changed"

      issue |> Issue.changeset(%{state: "closed"}) |> Repo.update!()
      assert Stalls.dispatch_rejected(@now) == []
    end

    test "a closed issue or a newer job settles the rejection", %{repository: repository} do
      issue = issue_fixture(repository, %{number: 82, workflow_label: "ptc:ready"})
      closed = job!(issue, %{state: "cancelled", ended_at: seconds_ago(120)})
      audit_job!(closed, "job.dispatch_rejected", %{"reason" => "issue_closed"}, 120)
      assert Stalls.dispatch_rejected(@now) == []

      other = issue_fixture(repository, %{number: 83, workflow_label: "ptc:ready"})
      rejected = job!(other, %{state: "cancelled", ended_at: seconds_ago(60)})
      audit_job!(rejected, "job.dispatch_rejected", %{"reason" => "issue_claimed"}, 60)
      assert [_stall] = Stalls.dispatch_rejected(@now)

      job!(other, %{state: "queued"})
      assert Stalls.dispatch_rejected(@now) == []
    end
  end

  describe "publication_stuck_green/1" do
    test "a green reviewed member pull request with no merge action is an alarm", %{
      repository: repository
    } do
      {_run, [member | _]} = run_fixture(repository, [91, 92])
      publication = green_publication!(member, 300)

      assert [%{kind: :publication_stuck_green, severity: :alarm, target_id: id, detail: detail}] =
               Stalls.publication_stuck_green(@now)

      assert id == publication.id
      assert detail =~ "##{publication.pr_number}"
    end

    test "a merge action, a fresh poll, or a run without automatic merging is not stuck", %{
      repository: repository
    } do
      {run, [member | _]} = run_fixture(repository, [91, 92])
      publication = green_publication!(member, 30)
      assert Stalls.publication_stuck_green(@now) == []

      Repo.update_all(from(p in PrPublication, where: p.id == ^publication.id),
        set: [pr_checked_at: seconds_ago(300)]
      )

      assert [_stall] = Stalls.publication_stuck_green(@now)

      action!(repository, "merge_reviewed_pr", "pull_request", publication.id, "queued", nil)
      assert Stalls.publication_stuck_green(@now) == []

      Repo.delete_all(AgentAction)

      action!(
        repository,
        "merge_reviewed_pr",
        "pull_request",
        publication.id + 1000,
        "running",
        nil
      )

      assert Stalls.publication_stuck_green(@now) == [], "the repository's merge lock is held"

      Repo.delete_all(AgentAction)

      action!(repository, "collection_handoff", "issue", run.issue_id, "running", nil,
        actor: "system:collection"
      )

      assert Stalls.publication_stuck_green(@now) == [], "a handoff is in flight"

      Repo.delete_all(AgentAction)
      {:ok, _repository} = Operations.set_repository_enabled(repository.id, false, "andreas")
      assert Stalls.publication_stuck_green(@now) == [], "a disabled repository is not reconciled"

      {:ok, _repository} = Operations.set_repository_enabled(repository.id, true, "andreas")
      run |> Run.changeset(%{auto_merge: false}) |> Repo.update!()
      assert Stalls.publication_stuck_green(@now) == []
    end
  end

  describe "agent_out_of_contact/1" do
    test "a working agent without a heartbeat for longer than the silence limit", %{
      repository: repository
    } do
      issue = issue_fixture(repository, %{number: 101, workflow_label: "ptc:ready"})
      job = job!(issue, %{state: "working"})
      worker = worker_fixture()

      {:ok, run} =
        Operations.create_agent_run(%{
          worker_id: worker.id,
          job_id: job.id,
          role: "implementer",
          state: "working",
          started_at: seconds_ago(1_800),
          last_heartbeat_at: seconds_ago(1_200)
        })

      assert [%{kind: :agent_out_of_contact, severity: :attention, target_id: id, detail: detail}] =
               Stalls.agent_out_of_contact(@now)

      assert id == run.id
      assert detail =~ "#101"

      {:ok, run} = Operations.update_agent_run(run, %{last_heartbeat_at: seconds_ago(5)})
      assert Stalls.agent_out_of_contact(@now) == []

      {:ok, _retained} =
        Operations.update_agent_run(run, %{
          state: "waiting",
          last_heartbeat_at: seconds_ago(1_200)
        })

      assert [%{kind: :agent_out_of_contact, since: since}] = Stalls.agent_out_of_contact(@now)
      assert since == seconds_ago(1_200)
    end
  end

  describe "detect/1" do
    test "lists alarms before attention items and oldest first", %{repository: repository} do
      issue = issue_fixture(repository, %{number: 111, workflow_label: "ptc:ready"})
      stopped_job!(issue, "environment_broken", "No network")
      operation!(repository, "running", 900)
      operation!(repository, "running", 600)

      assert [
               %{kind: :operation_slot_orphaned, since: first},
               %{kind: :operation_slot_orphaned, since: second},
               %{kind: :stop_unacknowledged}
             ] = Stalls.detect(@now)

      assert DateTime.compare(first, second) == :lt
    end
  end

  ## Fixtures

  defp run_fixture(repository, numbers, opts \\ []) do
    states = Keyword.get(opts, :states, %{})

    nodes =
      for number <- numbers do
        state = Map.get(states, number, "open")

        %{
          "number" => number,
          "state" => state,
          "state_reason" => if(state == "closed", do: "completed"),
          "repository_full_name" => Structure.repository_full_name(repository)
        }
      end

    umbrella =
      issue_fixture(repository, %{
        number: Enum.min(numbers) * 100,
        sub_issues: %{"nodes" => nodes, "total" => length(nodes)}
      })

    members =
      for number <- numbers do
        issue_fixture(repository, %{
          number: number,
          parent_issue_number: umbrella.number,
          workflow_label: "ptc:ready"
        })
      end

    run =
      %Run{}
      |> Run.changeset(%{
        repository_id: repository.id,
        issue_id: umbrella.id,
        state: "active",
        actor: "andreas",
        started_at: seconds_ago(120)
      })
      |> Repo.insert!()

    for member <- members do
      %Member{}
      |> Member.changeset(%{
        run_id: run.id,
        issue_number: member.number,
        issue_id: member.id,
        added_by: "start"
      })
      |> Repo.insert!()
    end

    {run, members}
  end

  defp close_completed!(issue) do
    issue
    |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
    |> Repo.update!()
  end

  defp age!(run, seconds) do
    at = seconds_ago(seconds)

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [started_at: at, inserted_at: at, updated_at: at]
    )
  end

  defp step!(run, kind, scope, seconds_ago) do
    %Step{}
    |> Step.changeset(%{run_id: run.id, kind: kind, scope: scope, actor: "system:collection"})
    |> Repo.insert!()
    |> then(fn step ->
      Repo.update_all(from(s in Step, where: s.id == ^step.id),
        set: [inserted_at: seconds_ago(seconds_ago)]
      )
    end)
  end

  defp audit!(run, action, seconds_ago) do
    event = ExecutionProfiles.audit("system:collection", action, run.id, %{}, "collection_run")
    backdate_audit!(event, seconds_ago)
  end

  defp audit_job!(job, action, details, seconds_ago) do
    event = ExecutionProfiles.audit("coordinator", action, job.id, details, "job")
    backdate_audit!(event, seconds_ago)
  end

  defp backdate_audit!(event, seconds_ago) do
    Repo.update_all(
      from(e in PtcManager.Operations.AuditEvent, where: e.id == ^event.id),
      set: [inserted_at: seconds_ago(seconds_ago)]
    )
  end

  defp job!(issue, attrs) do
    {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")

    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [execution_settings: nil])
    job |> Job.changeset(attrs) |> Repo.update!()
  end

  defp stopped_job!(issue, reason_code, summary) do
    job!(issue, %{
      state: "failed",
      last_error: summary,
      stop_report: %{"reason_code" => reason_code, "summary" => summary, "progress" => "none"},
      stop_reported_at: seconds_ago(600),
      stop_acknowledged_at: nil
    })
  end

  defp action!(repository, key, target_type, target_id, state, error, opts \\ []) do
    now = seconds_ago(0)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: key,
      target_type: target_type,
      target_id: target_id,
      target_label: "#{target_type} #{target_id}",
      prompt_version: 1,
      prompt: "test",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: Keyword.get(opts, :actor, "andreas"),
      state: state,
      attempt_count: 1,
      requested_at: now,
      ended_at: if(state in ["failed", "done"], do: now),
      last_error: error
    })
    |> Repo.insert!()
  end

  defp round!(job, number, state, findings) do
    %Round{}
    |> Round.changeset(%{
      job_id: job.id,
      fencing_token: job.fencing_token,
      generation: job.review_generation,
      number: number,
      request_id: "round-#{job.id}-#{number}",
      state: state,
      head_sha: String.duplicate("b", 40),
      base_sha: String.duplicate("a", 40),
      diff_digest: String.duplicate("c", 64),
      input: %{},
      expires_at: seconds_ago(-3_600),
      result:
        findings &&
          %{
            "summary" => "reviewed",
            "findings" =>
              Enum.map(findings, fn
                {severity, description} ->
                  %{"severity" => severity, "description" => description}

                description ->
                  %{"severity" => "medium", "description" => description}
              end)
          }
    })
    |> Repo.insert!()
  end

  defp operation!(repository, state, heartbeat_seconds_ago) do
    worker = worker_fixture()
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    job = job!(issue, %{state: "working"})

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        role: "implementer",
        state: "working",
        started_at: seconds_ago(3_600),
        last_heartbeat_at: seconds_ago(1)
      })

    %ResourceOperation{}
    |> ResourceOperation.changeset(%{
      worker_id: worker.id,
      repository_id: repository.id,
      agent_run_id: run.id,
      job_id: job.id,
      invocation_id: "op-#{System.unique_integer([:positive])}",
      label: "test",
      priority: 100,
      state: state,
      slot_number: 1,
      queued_at: seconds_ago(heartbeat_seconds_ago + 60),
      started_at: seconds_ago(heartbeat_seconds_ago + 30),
      last_heartbeat_at: seconds_ago(heartbeat_seconds_ago),
      finished_at: if(state == "completed", do: seconds_ago(heartbeat_seconds_ago)),
      wrapper_pid: 4242
    })
    |> Repo.insert!()
  end

  defp green_publication!(member, checked_seconds_ago) do
    head = String.duplicate("b", 40)

    job =
      job!(member, %{
        state: "pr_open",
        review_state: "passed",
        reviewed_head_sha: head,
        result_head_sha: head
      })

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      repository_id: member.repository_id,
      state: "published",
      idempotency_key: String.duplicate("e", 64),
      fencing_token: job.fencing_token,
      branch_name: "ptc-manager/issue-#{member.number}",
      base_sha: String.duplicate("a", 40),
      head_sha: head,
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: member.number + 1000,
      pr_url: "https://example.test/pull/#{member.number + 1000}",
      remote_head_sha: head,
      remote_base_sha: String.duplicate("a", 40),
      published_at: seconds_ago(3_600),
      pr_state: "open",
      pr_checked_at: seconds_ago(checked_seconds_ago),
      mergeability: "mergeable",
      checks_state: "success"
    })
    |> Repo.insert!()
  end

  defp backdate!(schema, id, seconds) do
    Repo.update_all(from(row in schema, where: row.id == ^id),
      set: [updated_at: seconds_ago(seconds)]
    )
  end

  defp seconds_ago(seconds), do: DateTime.add(@now, -seconds, :second)
end
