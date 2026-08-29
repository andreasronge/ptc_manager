defmodule PtcManager.MaintainerActionsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.CodexAdapter
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AgentRun, AuditEvent, PrPublication, Proposal}
  alias PtcManager.Repo

  defmodule FakeAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(action) do
      send(Process.get(:agent_action_test_pid), {:ran_agent_action, action})

      {:ok,
       %{
         "outcome" => "ready",
         "private_summary" => "The issue is now clear enough to implement.",
         "why_it_matters" => "A clear issue saves implementation time.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "Inspected lib/example.ex and its tests.",
         "github_changes" => ["Applied ptc:ready"],
         "evidence" => ["Inspected lib/example.ex"],
         "created_issue_numbers" => []
       }}
    end
  end

  defmodule RetrospectiveAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(action) do
      send(Process.get(:agent_action_test_pid), {:ran_agent_action, action})

      {:ok,
       %{
         "outcome" => "followups-created",
         "private_summary" => "The retrospective found one concrete follow-up.",
         "why_it_matters" => "The follow-up prevents the same regression.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "The pull request left one edge case uncovered.",
         "github_changes" => ["Created issue #900"],
         "evidence" => ["Reviewed the merged diff"],
         "created_issue_numbers" => [900]
       }}
    end
  end

  defmodule NoFollowupsAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(action) do
      send(Process.get(:agent_action_test_pid), {:ran_agent_action, action})

      {:ok,
       %{
         "outcome" => "no-followups",
         "private_summary" => "No concrete follow-up was needed.",
         "why_it_matters" => "The current issue set covers the work.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "Reviewed the pull request and checks.",
         "github_changes" => [],
         "evidence" => ["Reviewed the merged diff"],
         "created_issue_numbers" => []
       }}
    end
  end

  defmodule RetrospectiveSync do
    def sync_action(action) do
      call_count = Process.get(:retrospective_sync_call_count, 0) + 1
      Process.put(:retrospective_sync_call_count, call_count)

      if rem(call_count, 2) == 0 do
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        digest = String.duplicate("a", 64)

        {:ok, _issue} =
          PtcManager.Operations.create_issue(%{
            repository_id: action.repository_id,
            number: 900,
            title: "Follow up the retrospective finding",
            html_url: "https://github.com/example/repo/issues/900",
            state: "open",
            body: "Discovered while reviewing PR #81.",
            body_digest: digest,
            content_digest: digest,
            github_updated_at: now,
            workflow_label: nil,
            workflow_label_conflict: false
          })
      end

      {:ok, %{repository: action.repository}}
    end
  end

  defmodule FakeSync do
    def sync_action(action) do
      send(Process.get(:agent_action_test_pid), {:synced_repository, action.repository_id})

      PtcManager.Operations.Issue
      |> PtcManager.Repo.get!(action.target_id)
      |> PtcManager.Operations.Issue.changeset(%{
        workflow_label: "ptc:ready",
        workflow_label_conflict: false
      })
      |> PtcManager.Repo.update!()

      {:ok, %{repository: action.repository}}
    end
  end

  defmodule NoopSync do
    def sync_action(action), do: {:ok, %{repository: action.repository}}
  end

  defmodule AlwaysFailSync do
    def sync_action(_action), do: {:error, :offline}
  end

  defmodule FlakySync do
    def sync_action(action) do
      send(Process.get(:agent_action_test_pid), {:sync_attempt, action.id})

      case Process.get(:agent_action_sync_result) do
        {:ok, _summary} = result ->
          PtcManager.Operations.Issue
          |> PtcManager.Repo.get!(action.target_id)
          |> PtcManager.Operations.Issue.changeset(%{
            workflow_label: "ptc:ready",
            workflow_label_conflict: false
          })
          |> PtcManager.Repo.update!()

          result

        result ->
          result
      end
    end
  end

  setup do
    Process.put(:agent_action_test_pid, self())
    Process.put(:retrospective_sync_call_count, 0)
    :ok
  end

  test "queues a generic issue action once with its immutable prompt" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 42})

    assert {:ok, action} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")
    assert action.state == "queued"
    assert action.action_key == "prepare_issue"
    assert action.target_type == "issue"
    assert action.target_id == issue.id
    assert action.target_label =~ "#42"
    assert action.prompt =~ "Choose exactly one outcome"
    assert action.prompt =~ "ptc:needs-decision"
    assert action.prompt =~ "Follow relevant links"
    assert action.prompt =~ "Do not sign in to third-party sites"

    assert {:error, :agent_action_already_active} =
             MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")

    assert Repo.aggregate(AgentAction, :count) == 1
    assert Repo.aggregate(AuditEvent, :count) == 1
  end

  test "runs a queued action, records agent activity, and resynchronizes GitHub" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    {:ok, queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: FakeAdapter, sync: FakeSync)

    assert_receive {:ran_agent_action, %{id: action_id}}
    assert action_id == queued.id
    assert_receive {:synced_repository, repository_id}
    assert repository_id == repository.id

    assert completed.state == "done"
    assert completed.attempt_count == 1
    assert completed.result_summary =~ "private_summary"

    proposal = Repo.get_by!(Proposal, issue_id: issue.id)
    assert proposal.readiness == "ready"
    assert proposal.plain_summary == "The issue is now clear enough to implement."

    run = Repo.get_by!(AgentRun, agent_action_id: completed.id)
    assert run.role == "manager"
    assert run.state == "done"
    assert run.ended_at

    audit_actions = Repo.all(from event in AuditEvent, select: event.action)
    assert "agent_action.queued" in audit_actions
    assert "agent_action.started" in audit_actions
    assert "agent_action.done" in audit_actions
  end

  test "catalog keeps retrospective follow-ups untriaged and allows no-op results" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 19})

    publication = %PtcManager.Operations.PrPublication{
      id: 7,
      pr_number: 81,
      pr_state: "merged"
    }

    assert {:ok, %{prompt: prompt}} =
             Catalog.build("pr_retrospective", %{
               repository: repository,
               issue: issue,
               publication: publication
             })

    assert prompt =~ "Creating zero issues is a valid"
    assert prompt =~ "without a managed `ptc:*` workflow label"
    assert prompt =~ "Search existing open and closed issues"
    assert prompt =~ "Follow relevant links"
  end

  test "validates outcomes for the selected action rather than only the shared schema" do
    result = %{
      "outcome" => "ready",
      "private_summary" => "Summary",
      "why_it_matters" => "Why",
      "scope" => "small",
      "risk" => "low",
      "technical_evidence" => "Evidence",
      "github_changes" => [],
      "evidence" => [],
      "created_issue_numbers" => []
    }

    assert :ok = CodexAdapter.validate_result(result, "prepare_issue")

    assert {:error, :invalid_agent_action_outcome} =
             CodexAdapter.validate_result(result, "pr_retrospective")

    retrospective = Map.put(result, "outcome", "no-followups")
    assert :ok = CodexAdapter.validate_result(retrospective, "pr_retrospective")

    assert {:error, :invalid_agent_action_outcome} =
             CodexAdapter.validate_result(retrospective, "prepare_issue")

    created =
      retrospective
      |> Map.put("outcome", "followups-created")
      |> Map.put("created_issue_numbers", [23])

    assert :ok = CodexAdapter.validate_result(created, "pr_retrospective")
  end

  test "verifies retrospective follow-up issue numbers against synchronized GitHub state" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = retrospective_publication_fixture(issue)

    assert {:ok, queued} =
             MaintainerActions.enqueue("pr_retrospective", publication.id, "andreas")

    assert queued.baseline_issue_numbers == %{"numbers" => []}
    issue_fixture(repository, %{number: 901, body: "Created while this action was queued."})

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: RetrospectiveAdapter, sync: RetrospectiveSync)

    assert completed.id == queued.id
    assert completed.state == "done"
    assert 901 in completed.baseline_issue_numbers["numbers"]

    second_repository = repository_fixture()
    second_issue = issue_fixture(second_repository)
    issue_fixture(second_repository, %{number: 900, body: "Already tracked from PR #81."})
    second_publication = retrospective_publication_fixture(second_issue)

    assert {:ok, queued_without_issue} =
             MaintainerActions.enqueue("pr_retrospective", second_publication.id, "andreas")

    assert {:ok, failed} =
             MaintainerActions.run_once(adapter: RetrospectiveAdapter, sync: NoopSync)

    assert failed.id == queued_without_issue.id
    assert failed.state == "failed"
    assert failed.last_error =~ "canonical_followup_issues_mismatch"

    third_repository = repository_fixture()
    third_issue = issue_fixture(third_repository)
    third_publication = retrospective_publication_fixture(third_issue)

    assert {:ok, no_followups} =
             MaintainerActions.enqueue("pr_retrospective", third_publication.id, "andreas")

    assert {:ok, unexpected_creation} =
             MaintainerActions.run_once(adapter: NoFollowupsAdapter, sync: RetrospectiveSync)

    assert unexpected_creation.id == no_followups.id
    assert unexpected_creation.state == "failed"
    assert unexpected_creation.last_error =~ "canonical_followup_issues_mismatch"
  end

  test "defers a retrospective when its immediate pre-action GitHub sync fails" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = retrospective_publication_fixture(issue)

    assert {:ok, queued} =
             MaintainerActions.enqueue("pr_retrospective", publication.id, "andreas")

    assert {:ok, deferred} =
             MaintainerActions.run_once(adapter: RetrospectiveAdapter, sync: AlwaysFailSync)

    assert deferred.id == queued.id
    assert deferred.state == "queued"
    assert deferred.next_sync_attempt_at
    assert deferred.last_error =~ "Preflight GitHub synchronization pending"
    refute_receive {:ran_agent_action, _action}
  end

  test "does not trust a claimed outcome that GitHub synchronization did not confirm" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    {:ok, queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")

    assert {:ok, failed} = MaintainerActions.run_once(adapter: FakeAdapter, sync: NoopSync)
    assert failed.id == queued.id
    assert failed.state == "failed"
    assert failed.last_error =~ "github_outcome_mismatch"
    refute Repo.get_by(Proposal, issue_id: issue.id)
  end

  test "an expired mutating attempt is never replayed automatically" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    {:ok, queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")
    started_at = ~U[2026-08-29 10:00:00.000000Z]

    assert {:ok, {running, _token}} = Operations.claim_next_agent_action(started_at)
    assert running.id == queued.id

    after_deadline = DateTime.add(running.attempt_expires_at, 1, :second)
    assert Operations.expire_agent_action_attempts(after_deadline) == 1

    expired = Repo.get!(AgentAction, queued.id)
    assert expired.state == "sync_pending"
    assert expired.last_error =~ "may contain partial changes"
    assert {:ok, nil} = Operations.claim_next_agent_action(after_deadline)

    run = Repo.get_by!(AgentRun, agent_action_id: queued.id)
    assert run.state == "lost"
    assert run.status_text =~ "unknown GitHub outcome"

    assert {:ok, failed} = MaintainerActions.run_once(adapter: FakeAdapter, sync: FakeSync)
    assert failed.state == "failed"
    assert failed.last_error =~ "stopped reporting before the deadline"
    refute failed.next_sync_attempt_at
    refute_receive {:ran_agent_action, _action}
  end

  test "a synchronization failure is durable and retries without rerunning the agent" do
    previous_base = Application.get_env(:ptc_manager, :agent_action_sync_retry_base_ms)
    previous_max = Application.get_env(:ptc_manager, :agent_action_sync_retry_max_ms)

    Application.put_env(:ptc_manager, :agent_action_sync_retry_base_ms, 1)
    Application.put_env(:ptc_manager, :agent_action_sync_retry_max_ms, 1)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :agent_action_sync_retry_base_ms, previous_base)
      Application.put_env(:ptc_manager, :agent_action_sync_retry_max_ms, previous_max)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    {:ok, queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")
    Process.put(:agent_action_sync_result, {:error, :offline})

    assert {:ok, pending} =
             MaintainerActions.run_once(adapter: FakeAdapter, sync: FlakySync)

    assert pending.id == queued.id
    assert pending.state == "sync_pending"
    assert pending.result_summary =~ "private_summary"
    assert pending.last_error =~ "synchronization pending"
    assert_receive {:ran_agent_action, %{id: action_id}}
    assert action_id == queued.id
    assert_receive {:sync_attempt, ^action_id}

    Process.put(:agent_action_sync_result, {:ok, %{issue_number: issue.number}})
    Process.sleep(2)
    assert {:ok, completed} = MaintainerActions.run_once(adapter: FakeAdapter, sync: FlakySync)
    assert completed.state == "done"
    assert_receive {:sync_attempt, ^action_id}
    refute_receive {:ran_agent_action, _action}
  end

  test "pending synchronization blocks only its own repository queue" do
    first_repository = repository_fixture()
    first_issue = issue_fixture(first_repository)
    {:ok, first} = MaintainerActions.enqueue("prepare_issue", first_issue.id, "andreas")
    {:ok, {running, token}} = Operations.claim_next_agent_action()

    assert {:ok, pending} =
             Operations.mark_agent_action_sync_pending(
               running.id,
               token,
               {:error, :crashed},
               :offline
             )

    assert pending.id == first.id

    second_repository = repository_fixture()
    second_issue = issue_fixture(second_repository)
    {:ok, second} = MaintainerActions.enqueue("prepare_issue", second_issue.id, "andreas")

    assert {:ok, {claimed, _token}} = Operations.claim_next_agent_action()
    assert claimed.id == second.id
    assert claimed.repository_id == second_repository.id
  end

  defp retrospective_publication_fixture(issue) do
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      state: "published",
      idempotency_key:
        :crypto.hash(:sha256, "retrospective-publication-#{issue.id}")
        |> Base.encode16(case: :lower),
      fencing_token: job.fencing_token,
      branch_name: "ptc/issue-#{issue.number}",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: 81,
      pr_url: "https://github.com/example/repo/pull/81",
      remote_head_sha: String.duplicate("b", 40),
      published_at: DateTime.utc_now(),
      pr_state: "merged",
      source: "broker"
    })
    |> Repo.insert!()
  end
end
