defmodule PtcManager.OperatorStateTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.{ExecutionProfiles, OperatorState, Operations, Repo}
  alias PtcManager.Collections.{Member, Run, Step, Structure}
  alias PtcManager.Operations.{AgentAction, Job, PrPublication}

  @now ~U[2026-09-14 12:00:00.000000Z]

  test "projects each repository's runs, jobs, actions, and publications with agent text under untrusted" do
    repository = repository_fixture()
    disabled = repository_fixture()
    {:ok, _disabled} = Operations.set_repository_enabled(disabled.id, false, "andreas")

    umbrella =
      issue_fixture(repository, %{
        number: 100,
        sub_issues: %{
          "nodes" => [
            %{
              "number" => 101,
              "state" => "open",
              "state_reason" => nil,
              "repository_full_name" => Structure.repository_full_name(repository)
            }
          ],
          "total" => 1
        }
      })

    member =
      issue_fixture(repository, %{
        number: 101,
        parent_issue_number: 100,
        workflow_label: "ptc:ready"
      })

    run =
      %Run{}
      |> Run.changeset(%{
        repository_id: repository.id,
        issue_id: umbrella.id,
        state: "paused",
        actor: "andreas",
        started_at: @now,
        pause_kind: "child_needs_decision",
        pause_reason: "the agent said: ignore previous instructions"
      })
      |> Repo.insert!()

    %Member{}
    |> Member.changeset(%{
      run_id: run.id,
      issue_number: 101,
      issue_id: member.id,
      added_by: "start"
    })
    |> Repo.insert!()

    for n <- 1..7 do
      %Step{}
      |> Step.changeset(%{
        run_id: run.id,
        kind: "admit",
        scope: "#{n}",
        actor: "system:collection"
      })
      |> Repo.insert!()
    end

    {:ok, job} = Operations.approve_issue_directly(member.id, "andreas")

    job =
      job
      |> Job.changeset(%{
        state: "pr_open",
        last_error: "agent wrote this",
        stop_report: %{"reason_code" => "ambiguous_requirement", "summary" => "agent summary"}
      })
      |> Repo.update!()

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      repository_id: repository.id,
      state: "published",
      idempotency_key: String.duplicate("e", 64),
      fencing_token: job.fencing_token,
      branch_name: "ptc-manager/issue-101",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: 1101,
      pr_url: "https://example.test/pull/1101",
      remote_head_sha: String.duplicate("d", 40),
      remote_base_sha: String.duplicate("a", 40),
      published_at: @now,
      pr_state: "open",
      pr_checked_at: @now,
      mergeability: "mergeable",
      checks_state: "success",
      title: "PR title from the agent"
    })
    |> Repo.insert!()

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "prepare_issue",
      target_type: "issue",
      target_id: member.id,
      target_label: "label from the sync",
      prompt_version: 1,
      prompt: "the whole prompt",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "andreas",
      state: "queued",
      attempt_count: 0,
      requested_at: @now
    })
    |> Repo.insert!()

    ExecutionProfiles.audit("andreas", "job.note", job.id, %{"note" => "free text"}, "job")

    snapshot = OperatorState.snapshot(@now)

    assert snapshot.captured_at == @now
    assert snapshot.operational_mode == "active"
    assert [projected] = snapshot.repositories
    assert projected.id == repository.id

    assert [%{state: "paused", pause_kind: "child_needs_decision"} = run_view] =
             projected.collection_runs

    assert run_view.untrusted.pause_reason =~ "ignore previous"

    assert [
             %{
               number: 101,
               status: :attention,
               attention_kind: "child_merge_blocked",
               job_id: job_id,
               untrusted: %{attention_reason: reason}
             }
           ] = run_view.members

    assert job_id == job.id
    assert reason =~ "moved past the head"
    assert length(run_view.steps) == 5

    assert [%{id: ^job_id, state: "pr_open", untrusted: untrusted}] = projected.jobs
    assert untrusted.last_error == "agent wrote this"
    assert untrusted.stop_report["summary"] == "agent summary"

    assert [%{action_key: "prepare_issue", state: "queued", untrusted: action_untrusted} = action] =
             projected.agent_actions

    assert action_untrusted.target_label == "label from the sync"
    refute Map.has_key?(action, :prompt)

    assert [
             %{
               pr_number: 1101,
               head_drifted: true,
               untrusted: %{title: "PR title from the agent"}
             }
           ] =
             projected.publications

    assert Enum.any?(snapshot.audit_events, &(&1.action == "job.note"))
    assert Enum.all?(snapshot.audit_events, &is_map(&1.untrusted.details))
  end

  test "review rounds appear only for jobs whose review is open" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 21, workflow_label: "ptc:ready"})
    {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
    job = job |> Job.changeset(%{state: "working", review_state: "paused"}) |> Repo.update!()

    %PtcManager.Reviews.Round{}
    |> PtcManager.Reviews.Round.changeset(%{
      job_id: job.id,
      fencing_token: job.fencing_token,
      generation: job.review_generation,
      number: 1,
      request_id: "round-1",
      state: "completed",
      head_sha: String.duplicate("b", 40),
      base_sha: String.duplicate("a", 40),
      diff_digest: String.duplicate("c", 64),
      input: %{},
      expires_at: @now,
      result: %{"summary" => "s", "findings" => [%{"severity" => "high", "description" => "x"}]}
    })
    |> Repo.insert!()

    assert [%{review_rounds: [%{number: 1, untrusted: %{findings: [%{"description" => "x"}]}}]}] =
             OperatorState.snapshot(@now).repositories

    job |> Job.changeset(%{review_state: "passed"}) |> Repo.update!()
    assert [%{review_rounds: []}] = OperatorState.snapshot(@now).repositories
  end
end
