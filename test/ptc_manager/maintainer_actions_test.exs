defmodule PtcManager.MaintainerActionsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.CodexAdapter
  alias PtcManager.MaintainerActions.RetainedHerdrAdapter
  alias PtcManager.MaintainerActions.Sync
  alias PtcManager.MergeDecisions
  alias PtcManager.Operations
  alias PtcManager.PromptConfiguration

  alias PtcManager.Operations.{
    AgentAction,
    AgentRun,
    AuditEvent,
    MergeApproval,
    PrAnalysis,
    PrPublication,
    Proposal,
    WorktreeAllocation
  }

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
         "outcome" => "followups-proposed",
         "private_summary" => "The retrospective found one concrete follow-up.",
         "why_it_matters" => "The follow-up prevents the same regression.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "The pull request left one edge case uncovered.",
         "github_changes" => [],
         "evidence" => ["Reviewed the merged diff"],
         "created_issue_numbers" => [],
         "suggestions" => [
           %{
             "title" => "Cover the retry edge case",
             "simple_summary" => "One unusual retry can still behave unexpectedly.",
             "why_it_matters" => "It could repeat the regression.",
             "category" => "potential-bug",
             "technical_evidence" => "The merged diff does not cover the retry edge case.",
             "suggested_issue_body" => "Investigate the retry edge case found in PR #81."
           }
         ]
       }}
    end
  end

  defmodule RetrospectiveIssueAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(action) do
      send(Process.get(:agent_action_test_pid), {:ran_agent_action, action})

      {:ok,
       %{
         "outcome" => "followups-created",
         "private_summary" => "The approved follow-up was created.",
         "why_it_matters" => "The work is now visible in the planning inbox.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "The new issue links to the source pull request.",
         "github_changes" => ["Created issue #900"],
         "evidence" => ["Created one unlabelled issue"],
         "created_issue_numbers" => [900],
         "suggestions" => []
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

  defmodule MergeDecisionAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(action) do
      send(Process.get(:agent_action_test_pid), {:ran_agent_action, action})

      {:ok,
       %{
         "outcome" => "merge-ready",
         "private_summary" => "This PR safely fixes the reported retry bug.",
         "why_it_matters" => "It prevents duplicate work without widening the change.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "The focused tests and required reviews are green.",
         "github_changes" => [],
         "evidence" => ["Reviewed checks, reviews, discussion, and diff"],
         "created_issue_numbers" => []
       }}
    end
  end

  defmodule RepairAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(action) do
      send(Process.get(:agent_action_test_pid), {:ran_agent_action, action})

      {:ok,
       %{
         "outcome" => "repaired",
         "private_summary" => "The failing check was fixed on the existing PR branch.",
         "why_it_matters" => "The pull request can return to CI review.",
         "scope" => "small",
         "risk" => "low",
         "technical_evidence" => "Focused tests and two review passes completed.",
         "github_changes" => ["Pushed a repair commit to the existing branch"],
         "evidence" => ["The repaired commit was pushed without force"],
         "created_issue_numbers" => []
       }}
    end
  end

  defmodule RetainedHerdrCommand do
    def run(args, timeout) do
      send(Process.get(:agent_action_test_pid), {:retained_herdr_prompt, args, timeout})
      if callback = Process.get(:retained_herdr_callback), do: callback.()

      Process.get(
        :retained_herdr_result,
        {:ok, ~s({"result":{"agent_status":"done"}})}
      )
    end
  end

  defmodule MergeDecisionSync do
    def sync_action(_action) do
      [status | remaining] = Process.get(:merge_decision_statuses)
      Process.put(:merge_decision_statuses, remaining)
      {:ok, %{pull_request: status}}
    end
  end

  defmodule MergeDecisionClient do
    @behaviour PtcManager.GitHub.PullRequests
    def status(_publication), do: Process.get(:merge_approval_status)
  end

  defmodule RepairClient do
    @behaviour PtcManager.GitHub.PullRequests

    def status(_publication) do
      case Process.get(:repair_status) do
        {kind, _reason} = result when kind in [:retry, :blocked] -> result
        status -> {:ok, status}
      end
    end
  end

  defmodule RepairBaseFetcher do
    def fetch_base_for_verification(path, repository, expected_sha) do
      send(
        Process.get(:agent_action_test_pid),
        {:repair_base_fetch, path, repository.id, expected_sha}
      )

      Process.get(:repair_base_fetch_result, {:retry, :offline})
    end
  end

  defmodule RepairSync do
    def sync_action(_action) do
      [status | remaining] = Process.get(:merge_decision_statuses)
      Process.put(:merge_decision_statuses, remaining)
      {:ok, %{pull_request: status}}
    end

    def sync_action(action, result) do
      send(Process.get(:agent_action_test_pid), {:repair_postflight, result})
      sync_action(action)
    end
  end

  defmodule DeferredRepairSync do
    def sync_action(_action), do: {:ok, %{pull_request: Process.get(:repair_preflight_status)}}

    def sync_action(_action, result) do
      send(Process.get(:agent_action_test_pid), {:deferred_repair_postflight, result})
      attempts = Process.get(:deferred_repair_sync_attempts, 0) + 1
      Process.put(:deferred_repair_sync_attempts, attempts)

      if attempts == 1,
        do: {:error, :repair_head_not_visible},
        else: {:ok, %{pull_request: Process.get(:repair_postflight_status)}}
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

  test "review issue prompt runs at most three independent Codex consultations" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 43})

    assert {:ok, action} = MaintainerActions.enqueue("review_issue", issue.id, "andreas")
    assert action.action_key == "review_issue"
    assert action.prompt =~ "`codex-review` skill in `consult` mode"
    assert action.prompt =~ "Run at most 3 fresh review passes"
    assert action.prompt =~ "Stop early when a pass reports no actionable findings"
    assert action.prompt =~ "you, the primary maintainer, must sanity-check their findings"
    assert action.prompt =~ "Do not invoke nested reviewers"
    assert action.prompt =~ "leave exactly `ptc:ready`"
    assert action.prompt =~ "Return empty `created_issue_numbers` and `suggestions` arrays"
  end

  test "serializes different maintainer actions for the same issue" do
    repository = repository_fixture()
    issue = issue_fixture(repository)

    assert {:ok, _action} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")

    assert {:error, :agent_action_already_active} =
             MaintainerActions.enqueue("review_issue", issue.id, "andreas")

    assert Repo.aggregate(AgentAction, :count) == 1
  end

  test "does not misreport target validation errors as active-action conflicts" do
    repository = repository_fixture()

    attrs = %{
      repository_id: repository.id,
      action_key: "invalid_target_test",
      target_type: "unsupported",
      target_id: 99,
      target_label: "invalid",
      prompt_version: 1,
      prompt: "No operation",
      actor: "andreas"
    }

    assert {:error, changeset} = Operations.enqueue_agent_action(attrs)
    assert changeset.errors[:target_type]
    refute changeset.errors[:action_key]
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
      job_id: 1,
      source: "agent",
      pr_number: 81,
      pr_state: "merged"
    }

    assert {:ok, %{prompt: prompt}} =
             Catalog.build("pr_retrospective", %{
               repository: repository,
               issue: issue,
               publication: publication
             })

    assert prompt =~ "Returning zero suggestions is valid"
    assert prompt =~ "Do not create or modify GitHub issues"
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
      "created_issue_numbers" => [],
      "suggestions" => []
    }

    assert :ok = CodexAdapter.validate_result(result, "prepare_issue")
    assert :ok = CodexAdapter.validate_result(result, "review_issue")

    assert {:error, :invalid_agent_action_outcome} =
             CodexAdapter.validate_result(result, "pr_retrospective")

    retrospective = Map.put(result, "outcome", "no-followups")
    assert :ok = CodexAdapter.validate_result(retrospective, "pr_retrospective")

    assert {:error, :invalid_agent_action_outcome} =
             CodexAdapter.validate_result(retrospective, "prepare_issue")

    assert {:error, :invalid_agent_action_outcome} =
             CodexAdapter.validate_result(retrospective, "review_issue")

    proposed =
      retrospective
      |> Map.put("outcome", "followups-proposed")
      |> Map.put("suggestions", [
        %{
          "title" => "Investigate retry behavior",
          "simple_summary" => "A rare retry may still fail.",
          "why_it_matters" => "Users could lose work.",
          "category" => "potential-bug",
          "technical_evidence" => "The edge case has no test.",
          "suggested_issue_body" => "Investigate the retry behavior found in PR #23."
        }
      ])

    assert :ok = CodexAdapter.validate_result(proposed, "pr_retrospective")

    created =
      retrospective
      |> Map.put("outcome", "followups-created")
      |> Map.put("created_issue_numbers", [23])

    assert :ok = CodexAdapter.validate_result(created, "create_retrospective_issue")

    merge_result =
      result
      |> Map.put("outcome", "merge-ready")

    assert :ok = CodexAdapter.validate_result(merge_result, "prepare_merge_decision")

    repair_result = Map.put(result, "outcome", "repaired")
    assert :ok = CodexAdapter.validate_result(repair_result, "repair_pr")

    assert {:error, :unexpected_github_changes} =
             merge_result
             |> Map.put("github_changes", ["Approved the PR"])
             |> CodexAdapter.validate_result("prepare_merge_decision")
  end

  test "stores a private merge decision only when the exact PR version is unchanged" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    status = merge_status(publication, repository)

    assert {:ok, queued} =
             MaintainerActions.enqueue("prepare_merge_decision", publication.id, "andreas")

    assert queued.prompt =~ "read-only investigation"
    assert queued.prompt =~ "Follow relevant links"
    assert queued.prompt =~ "exact GitHub head and base SHAs"

    Process.put(:merge_decision_statuses, [status, status])

    assert {:ok, completed} =
             MaintainerActions.run_once(
               adapter: MergeDecisionAdapter,
               sync: MergeDecisionSync
             )

    assert completed.state == "done"
    assert completed.target_snapshot == MergeDecisions.snapshot(status)

    analysis = Repo.get_by!(PrAnalysis, agent_action_id: completed.id)
    assert analysis.outcome == "merge-ready"
    assert analysis.head_sha == publication.remote_head_sha
    assert analysis.reviewed_base_sha == status.base_sha
    assert analysis.diff_digest == publication.diff_digest

    second_publication = open_publication_fixture(issue_fixture(repository, %{number: 99}))
    first = merge_status(second_publication, repository)
    changed = %{first | base_sha: String.duplicate("e", 40)}

    assert {:ok, second_action} =
             MaintainerActions.enqueue(
               "prepare_merge_decision",
               second_publication.id,
               "andreas"
             )

    Process.put(:merge_decision_statuses, [first, changed])

    assert {:ok, failed} =
             MaintainerActions.run_once(
               adapter: MergeDecisionAdapter,
               sync: MergeDecisionSync
             )

    assert failed.id == second_action.id
    assert failed.state == "failed"
    assert failed.last_error =~ "pull_request_changed_during_analysis"
    refute Repo.get_by(PrAnalysis, agent_action_id: second_action.id)
  end

  test "queues and executes a repair for a failing open pull request" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    retain_repair_worktree(publication)

    publication =
      publication
      |> PrPublication.changeset(%{
        checks_state: "failure",
        checks_total: 2,
        checks_failed: 1,
        checks_pending: 0,
        mergeability: "mergeable"
      })
      |> Repo.update!()

    assert {:ok, _} =
             PromptConfiguration.save(
               "repair_pr",
               "Use the instructions captured when this repair was queued.",
               "andreas"
             )

    assert {:ok, queued} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")
    assert queued.state == "queued"
    assert queued.prompt =~ "Repair the existing"
    assert queued.prompt =~ "uncommitted changes from an earlier interrupted repair attempt"
    assert queued.prompt =~ "codex-review"
    assert queued.prompt =~ "Never use `--force`"
    assert queued.prompt =~ "instructions captured when this repair was queued"

    assert {:ok, _} =
             PromptConfiguration.save(
               "repair_pr",
               "This later configuration must not rewrite queued repair work.",
               "andreas"
             )

    failing_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{
        checks_state: "failure",
        mergeability: "mergeable"
      })

    repaired_status =
      Map.merge(failing_status, %{
        head_sha: String.duplicate("e", 40),
        checks_state: "pending",
        mergeability: "unknown"
      })

    Process.put(:merge_decision_statuses, [failing_status, repaired_status])

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: RepairAdapter, sync: RepairSync)

    assert completed.id == queued.id
    assert completed.state == "done"
    assert completed.target_snapshot == MergeDecisions.snapshot(failing_status)
    assert Repo.get_by!(AgentRun, agent_action_id: completed.id).state == "done"
    assert_receive {:ran_agent_action, executed}
    assert executed.prompt =~ "instructions captured when this repair was queued"
    refute executed.prompt =~ "later configuration must not rewrite"
    assert_receive {:repair_postflight, {:ok, %{"outcome" => "repaired"}}}
  end

  test "fails a repair safely when its retained worktree is unavailable" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)

    publication
    |> PrPublication.changeset(%{checks_state: "failure", mergeability: "mergeable"})
    |> Repo.update!()

    assert {:ok, queued} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{checks_state: "failure", mergeability: "mergeable"})

    Process.put(:merge_decision_statuses, [status])

    assert {:ok, failed} =
             MaintainerActions.run_once(adapter: RepairAdapter, sync: RepairSync)

    assert failed.id == queued.id
    assert failed.state == "failed"
    assert failed.last_error =~ "repair_worktree_not_available"
    refute_receive {:ran_agent_action, _action}
  end

  test "fails a claimed repair when the retained branch did not advance" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)

    publication =
      publication
      |> PrPublication.changeset(%{
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha
      })
      |> Repo.update!()

    publication
    |> PrPublication.changeset(%{checks_state: "failure", mergeability: "mergeable"})
    |> Repo.update!()

    status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{checks_state: "failure", mergeability: "mergeable"})

    Process.put(:repair_status, status)

    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(status)
             )

    assert {:ok, _reserved} =
             Operations.reserve_worktree_for_repair(publication.job_id, "repair-agent")

    assert {:terminal_error, :repair_agent_did_not_advance_head} =
             Sync.sync_action(prepared, {:ok, %{"outcome" => "repaired"}})

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "attention"
  end

  test "a deferred repair reconciliation reuses the stored agent result" do
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
    publication = open_publication_fixture(issue)
    retain_repair_worktree(publication)

    publication =
      publication
      |> PrPublication.changeset(%{checks_state: "failure", mergeability: "mergeable"})
      |> Repo.update!()

    failing_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{checks_state: "failure", mergeability: "mergeable"})

    Process.put(:repair_preflight_status, failing_status)

    Process.put(:repair_postflight_status, %{failing_status | head_sha: String.duplicate("e", 40)})

    Process.put(:deferred_repair_sync_attempts, 0)

    assert {:ok, queued} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, pending} =
             MaintainerActions.run_once(adapter: RepairAdapter, sync: DeferredRepairSync)

    assert pending.id == queued.id
    assert pending.state == "sync_pending"
    assert_receive {:ran_agent_action, %{id: action_id}}
    assert action_id == queued.id
    assert_receive {:deferred_repair_postflight, {:ok, %{"outcome" => "repaired"}}}

    Process.sleep(2)

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: RepairAdapter, sync: DeferredRepairSync)

    assert completed.state == "done"
    assert_receive {:deferred_repair_postflight, {:ok, %{"outcome" => "repaired"}}}
    refute_receive {:ran_agent_action, _action}
  end

  test "accepts a clean fast-forward repair verified from the retained worktree" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)
    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)

    publication =
      publication
      |> PrPublication.changeset(%{
        branch_name: job.branch_name,
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })
      |> Repo.update!()

    old_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{
        head_ref: job.branch_name,
        base_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })

    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(old_status)
             )

    assert {:ok, _reserved} =
             Operations.reserve_worktree_for_repair(publication.job_id, "repair-agent")

    File.write!(Path.join(allocation.path, "README.md"), "published\nrepaired\n")
    git!(allocation.path, ["commit", "-am", "repair failing CI"])
    repaired_head = git!(allocation.path, ["rev-parse", "HEAD"]) |> String.trim()

    repaired_status =
      old_status
      |> Map.merge(%{
        head_sha: repaired_head,
        checks_state: "pending",
        checks_failed: 0,
        checks_pending: 1,
        mergeability: "unknown"
      })

    Process.put(:repair_status, repaired_status)

    assert {:ok, %{pull_request: ^repaired_status}} =
             Sync.sync_action(prepared, {:ok, %{"outcome" => "repaired"}})

    repaired = Repo.get!(PrPublication, publication.id)
    assert repaired.remote_head_sha == repaired_head
    assert repaired.state == "published"
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "waiting"
  end

  test "a PR repair resumes the original named Herdr implementation session" do
    previous_command = Application.get_env(:ptc_manager, :herdr_command)
    Application.put_env(:ptc_manager, :herdr_command, RetainedHerdrCommand)
    on_exit(fn -> Application.put_env(:ptc_manager, :herdr_command, previous_command) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)

    publication =
      issue
      |> open_publication_fixture()
      |> PrPublication.changeset(%{checks_state: "failure", checks_failed: 1})
      |> Repo.update!()

    allocation =
      publication
      |> retain_real_repair_worktree(issue)
      |> WorktreeAllocation.changeset(%{state: "active"})
      |> Repo.update!()

    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)
    worker = Repo.get!(PtcManager.Operations.Worker, allocation.worker_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, retained_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "waiting",
        status_text: "Waiting with open PR.",
        agent_name: "impl_j#{job.id}_f#{job.fencing_token}",
        herdr_workspace: "w-retained",
        herdr_pane: "w-retained:p1",
        herdr_session: "default",
        external_key: "default:retained-#{job.id}",
        started_at: DateTime.add(now, -300, :second),
        last_heartbeat_at: now,
        fencing_token: job.fencing_token
      })

    assert {:ok, queued} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")
    assert {:ok, {action, _token}} = Operations.claim_agent_action(queued.id)

    assert {:ok, %{"outcome" => "repaired"}} = RetainedHerdrAdapter.run(action)

    assert_receive {:retained_herdr_prompt, args, timeout}
    assert Enum.take(args, 3) == ["agent", "prompt", retained_run.agent_name]
    assert Enum.at(args, 3) =~ "reuse your prior context"
    assert "--wait" in args
    assert timeout > 0

    retained_run = Repo.get!(AgentRun, retained_run.id)
    assert retained_run.state == "waiting"
    refute retained_run.ended_at

    action_run = Repo.get_by!(AgentRun, agent_action_id: action.id)
    assert action_run.agent_name == retained_run.agent_name
    assert action_run.herdr_workspace == retained_run.herdr_workspace
    assert action_run.herdr_pane == retained_run.herdr_pane
  end

  test "a failed retained Herdr prompt keeps the slot occupied and marks the run unknown" do
    previous_command = Application.get_env(:ptc_manager, :herdr_command)
    Application.put_env(:ptc_manager, :herdr_command, RetainedHerdrCommand)
    Process.put(:retained_herdr_result, {:error, :herdr_timeout})

    on_exit(fn ->
      Application.put_env(:ptc_manager, :herdr_command, previous_command)
      Process.delete(:retained_herdr_result)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository)

    publication =
      issue
      |> open_publication_fixture()
      |> PrPublication.changeset(%{checks_state: "failure", checks_failed: 1})
      |> Repo.update!()

    allocation =
      publication
      |> retain_real_repair_worktree(issue)
      |> WorktreeAllocation.changeset(%{state: "active"})
      |> Repo.update!()

    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)
    worker = Repo.get!(PtcManager.Operations.Worker, allocation.worker_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, retained_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "waiting",
        agent_name: "impl_j#{job.id}_f#{job.fencing_token}",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        fencing_token: job.fencing_token
      })

    assert {:ok, queued} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")
    assert {:ok, {action, _token}} = Operations.claim_agent_action(queued.id)
    assert {:error, :herdr_timeout} = RetainedHerdrAdapter.run(action)

    assert Repo.get!(AgentRun, retained_run.id).state == "unknown"
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "active"
  end

  test "terminal PR reconciliation wins a race with retained-agent settlement" do
    previous_command = Application.get_env(:ptc_manager, :herdr_command)
    Application.put_env(:ptc_manager, :herdr_command, RetainedHerdrCommand)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :herdr_command, previous_command)
      Process.delete(:retained_herdr_callback)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository)

    publication =
      issue
      |> open_publication_fixture()
      |> PrPublication.changeset(%{checks_state: "failure", checks_failed: 1})
      |> Repo.update!()

    allocation =
      publication
      |> retain_real_repair_worktree(issue)
      |> WorktreeAllocation.changeset(%{state: "active"})
      |> Repo.update!()

    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)
    worker = Repo.get!(PtcManager.Operations.Worker, allocation.worker_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, retained_run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        job_id: job.id,
        role: "implementer",
        state: "waiting",
        agent_name: "impl_j#{job.id}_f#{job.fencing_token}",
        started_at: DateTime.add(now, -60, :second),
        last_heartbeat_at: now,
        fencing_token: job.fencing_token
      })

    Process.put(:retained_herdr_callback, fn ->
      terminal_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Repo.get!(PrPublication, publication.id)
      |> PrPublication.changeset(%{pr_state: "merged", pr_checked_at: terminal_at})
      |> Repo.update!()

      Repo.get!(PtcManager.Operations.Job, job.id)
      |> PtcManager.Operations.Job.changeset(%{state: "done", ended_at: terminal_at})
      |> Repo.update!()

      Repo.get!(WorktreeAllocation, allocation.id)
      |> WorktreeAllocation.changeset(%{state: "terminal"})
      |> Repo.update!()

      Repo.get!(AgentRun, retained_run.id)
      |> AgentRun.changeset(%{state: "done", ended_at: terminal_at})
      |> Repo.update!()
    end)

    assert {:ok, queued} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")
    assert {:ok, {action, _token}} = Operations.claim_agent_action(queued.id)
    assert {:ok, %{"outcome" => "repaired"}} = RetainedHerdrAdapter.run(action)

    assert Repo.get!(AgentRun, retained_run.id).state == "done"
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "terminal"
  end

  test "a repaired result with untracked files moves the worktree to attention" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)
    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)

    publication =
      publication
      |> PrPublication.changeset(%{
        branch_name: job.branch_name,
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })
      |> Repo.update!()

    old_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{
        head_ref: job.branch_name,
        base_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })

    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(old_status)
             )

    assert {:ok, _reserved} = Operations.reserve_worktree_for_repair(publication.job_id)
    File.write!(Path.join(allocation.path, "README.md"), "published\nrepaired\n")
    git!(allocation.path, ["commit", "-am", "repair failing CI"])
    repaired_head = git!(allocation.path, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(allocation.path, "leftover.txt"), "untracked\n")
    repaired_status = %{old_status | head_sha: repaired_head}
    Process.put(:repair_status, repaired_status)

    assert {:terminal_error, :worktree_changed} =
             Sync.sync_action(prepared, {:ok, %{"outcome" => "repaired"}})

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "attention"
  end

  test "a missing postflight base uses the trusted fetcher before retrying" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    previous_fetcher = Application.get_env(:ptc_manager, :repair_base_fetcher)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    Application.put_env(:ptc_manager, :repair_base_fetcher, RepairBaseFetcher)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :pull_request_client, previous_client)
      Application.put_env(:ptc_manager, :repair_base_fetcher, previous_fetcher)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)
    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)

    publication =
      publication
      |> PrPublication.changeset(%{
        branch_name: job.branch_name,
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })
      |> Repo.update!()

    old_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{
        head_ref: job.branch_name,
        base_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })

    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(old_status)
             )

    assert {:ok, _reserved} = Operations.reserve_worktree_for_repair(publication.job_id)
    File.write!(Path.join(allocation.path, "README.md"), "published\nrepaired\n")
    git!(allocation.path, ["commit", "-am", "repair failing CI"])
    repaired_head = git!(allocation.path, ["rev-parse", "HEAD"]) |> String.trim()
    missing_base = String.duplicate("f", 40)
    Process.put(:repair_status, %{old_status | head_sha: repaired_head, base_sha: missing_base})

    assert {:error, :repair_base_missing} =
             Sync.sync_action(prepared, {:ok, %{"outcome" => "repaired"}})

    assert_receive {:repair_base_fetch, path, repository_id, ^missing_base}
    assert path == allocation.path
    assert repository_id == repository.id
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "active"
  end

  test "managed fix-and-merge uses one slot and records a same-turn repaired merge" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :pull_request_client, previous_client)
      Application.put_env(:ptc_manager, :dispatch_enabled, previous_dispatch)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)
    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)

    publication =
      publication
      |> PrPublication.changeset(%{
        branch_name: job.branch_name,
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })
      |> Repo.update!()

    old_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{
        head_ref: job.branch_name,
        base_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })

    assert {:ok, action} =
             MaintainerActions.enqueue("repair_and_merge_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(old_status)
             )

    assert {:ok, _reserved} = Operations.reserve_worktree_for_repair(publication.job_id)

    allocation_worker = Repo.get!(PtcManager.Operations.Worker, allocation.worker_id)

    allocation_worker
    |> PtcManager.Operations.Worker.changeset(%{
      worker_key: "herdr:default",
      status: "online",
      capabilities: %{"herdr" => true, "implementation_slots" => 1}
    })
    |> Repo.update!()

    assert {:ok, {claimed, _token}} = Operations.claim_agent_action(prepared.id)

    File.write!(Path.join(allocation.path, "README.md"), "published\nrepaired and merged\n")
    git!(allocation.path, ["commit", "-am", "repair before merge"])
    repaired_head = git!(allocation.path, ["rev-parse", "HEAD"]) |> String.trim()
    open_status = %{old_status | head_sha: repaired_head, checks_state: "success"}
    Process.put(:repair_status, %{open_status | state: "merged"})

    assert {:ok, %{publication: merged}} =
             Sync.sync_action(claimed, {:ok, %{"outcome" => "repaired"}})

    assert merged.pr_state == "merged"
    assert merged.remote_head_sha == repaired_head
    assert Repo.get!(PtcManager.Operations.Job, publication.job_id).state == "done"
  end

  test "a blocked postflight status moves the reserved worktree to attention" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)

    publication
    |> PrPublication.changeset(%{checks_state: "failure", mergeability: "mergeable"})
    |> Repo.update!()

    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")
    assert {:ok, _reserved} = Operations.reserve_worktree_for_repair(publication.job_id)
    Process.put(:repair_status, {:blocked, :github_auth_failed})

    assert {:terminal_error, :github_auth_failed} =
             Sync.sync_action(action, {:error, :adapter_failed})

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "attention"
  end

  test "a failed repair never releases a dirty worktree as reusable" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)

    publication =
      publication
      |> PrPublication.changeset(%{
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })
      |> Repo.update!()

    status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{checks_state: "failure", mergeability: "mergeable"})

    Process.put(:repair_status, status)
    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(status)
             )

    assert {:ok, _reserved} = Operations.reserve_worktree_for_repair(publication.job_id)
    File.write!(Path.join(allocation.path, "unfinished.txt"), "partial repair\n")

    assert {:terminal_error, :repair_execution_uncertain} =
             Sync.sync_action(prepared, {:error, :adapter_failed})

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "active"
  end

  test "stops waiting when an advanced repair head never becomes visible on GitHub" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    previous_limit = Application.get_env(:ptc_manager, :repair_visibility_sync_limit)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    Application.put_env(:ptc_manager, :repair_visibility_sync_limit, 1)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :pull_request_client, previous_client)
      Application.put_env(:ptc_manager, :repair_visibility_sync_limit, previous_limit)
    end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    allocation = retain_real_repair_worktree(publication, issue)

    publication =
      publication
      |> PrPublication.changeset(%{
        head_sha: allocation.head_sha,
        remote_head_sha: allocation.head_sha,
        checks_state: "failure",
        mergeability: "mergeable"
      })
      |> Repo.update!()

    old_status =
      publication
      |> merge_status(repository)
      |> Map.merge(%{checks_state: "failure", mergeability: "mergeable"})

    Process.put(:repair_status, old_status)
    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(old_status)
             )

    prepared =
      prepared
      |> AgentAction.changeset(%{sync_attempt_count: 1})
      |> Repo.update!()

    assert {:ok, _reserved} =
             Operations.reserve_worktree_for_repair(publication.job_id, "repair-agent")

    File.write!(Path.join(allocation.path, "README.md"), "published\nlocal repair\n")
    git!(allocation.path, ["commit", "-am", "repair not visible remotely"])

    assert {:terminal_error, :repair_head_visibility_timeout} =
             Sync.sync_action(prepared, {:ok, %{"outcome" => "repaired"}})

    assert Repo.get!(WorktreeAllocation, allocation.id).state == "attention"
  end

  test "repair reconciliation records a pull request closed during the attempt" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, RepairClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)

    publication =
      publication
      |> PrPublication.changeset(%{checks_state: "failure", mergeability: "mergeable"})
      |> Repo.update!()

    status = publication |> merge_status(repository) |> Map.put(:state, "closed")
    Process.put(:repair_status, status)

    assert {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "andreas")

    assert {:ok, prepared} =
             Operations.record_agent_action_target_snapshot(
               action.id,
               MergeDecisions.snapshot(status)
             )

    assert {:terminal_error, :pull_request_not_open} =
             Sync.sync_action(prepared, {:ok, %{"outcome" => "repair-blocked"}})

    assert Repo.get!(PrPublication, publication.id).pr_state == "closed"
    assert Repo.get!(PtcManager.Operations.Job, publication.job_id).state == "cancelled"
  end

  test "human merge approval is bound to the analyzed head, base, and diff" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    status = merge_status(publication, repository)

    {:ok, action} = MaintainerActions.enqueue("prepare_merge_decision", publication.id, "andreas")
    Process.put(:merge_decision_statuses, [status, status])

    assert {:ok, _completed} =
             MaintainerActions.run_once(
               adapter: MergeDecisionAdapter,
               sync: MergeDecisionSync
             )

    Process.put(:merge_approval_status, {:ok, status})

    assert {:ok, approval} =
             MergeDecisions.approve(publication.id, "andreas", client: MergeDecisionClient)

    assert approval.actor == "andreas"
    assert approval.head_sha == status.head_sha
    assert approval.reviewed_base_sha == status.base_sha
    assert approval.diff_digest == publication.diff_digest
    assert Repo.aggregate(MergeApproval, :count) == 1

    changed = %{status | base_sha: String.duplicate("e", 40)}
    Process.put(:merge_approval_status, {:ok, changed})

    assert {:error, :merge_analysis_stale} =
             MergeDecisions.approve(publication.id, "andreas", client: MergeDecisionClient)

    assert Repo.aggregate(MergeApproval, :count) == 1
    assert Repo.get!(AgentAction, action.id).state == "done"

    Process.put(:merge_approval_status, {:ok, status})

    assert {:ok, same_approval} =
             MergeDecisions.approve(publication.id, "andreas", client: MergeDecisionClient)

    assert same_approval.id == approval.id
    assert Repo.aggregate(MergeApproval, :count) == 1

    assert Repo.aggregate(
             from(event in AuditEvent, where: event.action == "merge_approval.approved"),
             :count
           ) == 1
  end

  test "a PR closed during merge-decision preflight fails without running or blocking the queue" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, MergeDecisionClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)
    closed = %{merge_status(publication, repository) | state: "closed"}
    Process.put(:merge_approval_status, {:ok, closed})

    assert {:ok, queued} =
             MaintainerActions.enqueue("prepare_merge_decision", publication.id, "andreas")

    assert {:ok, failed} = MaintainerActions.run_once(adapter: MergeDecisionAdapter)
    assert failed.id == queued.id
    assert failed.state == "failed"
    assert failed.last_error =~ "pull_request_not_open"
    refute_receive {:ran_agent_action, _action}

    assert {:ok, next_action} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")
    assert Operations.next_agent_action_candidate().id == next_action.id
  end

  test "a changed PR head during merge-decision preflight fails terminally" do
    previous_client = Application.get_env(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, MergeDecisionClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous_client) end)

    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = open_publication_fixture(issue)

    changed = %{
      merge_status(publication, repository)
      | head_sha: String.duplicate("e", 40)
    }

    Process.put(:merge_approval_status, {:ok, changed})

    assert {:ok, queued} =
             MaintainerActions.enqueue("prepare_merge_decision", publication.id, "andreas")

    assert {:ok, failed} = MaintainerActions.run_once(adapter: MergeDecisionAdapter)
    assert failed.id == queued.id
    assert failed.state == "failed"
    assert failed.last_error =~ "pull_request_not_open"
    assert Repo.get!(PrPublication, publication.id).state == "blocked"
    refute_receive {:ran_agent_action, _action}
  end

  test "keeps retrospective read-only and creates only an explicitly approved suggestion" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = retrospective_publication_fixture(issue)

    assert {:ok, queued} = enqueue_legacy_retrospective(publication, "andreas")

    assert queued.baseline_issue_numbers == %{"numbers" => []}
    issue_fixture(repository, %{number: 901, body: "Created while this action was queued."})

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: RetrospectiveAdapter, sync: NoopSync)

    assert completed.id == queued.id
    assert completed.state == "done"
    assert 901 in completed.baseline_issue_numbers["numbers"]

    assert {:ok, creation} =
             MaintainerActions.enqueue_retrospective_issue(completed.id, 0, "andreas")

    assert creation.action_key == "create_retrospective_issue"
    assert creation.target_snapshot["source_action_id"] == completed.id
    assert creation.target_snapshot["suggestion_index"] == 0

    assert {:error, :suggestion_already_handled} =
             MaintainerActions.enqueue_retrospective_issue(completed.id, 0, "andreas")

    assert {:ok, created} =
             MaintainerActions.run_once(
               adapter: RetrospectiveIssueAdapter,
               sync: RetrospectiveSync
             )

    assert created.id == creation.id
    assert created.state == "done"

    second_repository = repository_fixture()
    second_issue = issue_fixture(second_repository)
    issue_fixture(second_repository, %{number: 900, body: "Already tracked from PR #81."})
    second_publication = retrospective_publication_fixture(second_issue)

    assert {:ok, _queued_without_issue} =
             enqueue_legacy_retrospective(second_publication, "andreas")

    assert {:ok, proposal} =
             MaintainerActions.run_once(adapter: RetrospectiveAdapter, sync: NoopSync)

    assert proposal.state == "done"

    assert {:ok, duplicate_creation} =
             MaintainerActions.enqueue_retrospective_issue(proposal.id, 0, "andreas")

    assert {:ok, failed} =
             MaintainerActions.run_once(
               adapter: RetrospectiveIssueAdapter,
               sync: NoopSync
             )

    assert failed.id == duplicate_creation.id
    assert failed.state == "failed"
    assert failed.last_error =~ "canonical_followup_issues_mismatch"

    third_repository = repository_fixture()
    third_issue = issue_fixture(third_repository)
    third_publication = retrospective_publication_fixture(third_issue)

    assert {:ok, no_followups} = enqueue_legacy_retrospective(third_publication, "andreas")

    assert {:ok, unexpected_creation} =
             MaintainerActions.run_once(adapter: RetrospectiveAdapter, sync: RetrospectiveSync)

    assert unexpected_creation.id == no_followups.id
    assert unexpected_creation.state == "failed"
    assert unexpected_creation.last_error =~ "canonical_retrospective_proposal_mismatch"
  end

  test "does not accept new retrospective actions after the workflow is retired" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = retrospective_publication_fixture(issue)

    assert {:error, :unknown_agent_action} =
             MaintainerActions.enqueue("pr_retrospective", publication.id, "andreas")
  end

  test "defers a retrospective when its immediate pre-action GitHub sync fails" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    publication = retrospective_publication_fixture(issue)

    assert {:ok, queued} = enqueue_legacy_retrospective(publication, "andreas")

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

  test "fix-and-merge is selected before older ordinary agent actions" do
    repository = repository_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    ordinary =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "prepare_issue",
        target_type: "issue",
        target_id: 9_001,
        target_label: "example/repo#9001",
        prompt_version: 1,
        prompt: "Prepare issue",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "andreas",
        state: "queued",
        attempt_count: 0,
        requested_at: DateTime.add(now, -60, :second)
      })
      |> Repo.insert!()

    priority =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: 9_002,
        target_label: "example/repo#9002",
        prompt_version: 1,
        prompt: "Fix and merge the exact pull request",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "andreas",
        state: "queued",
        attempt_count: 0,
        requested_at: now
      })
      |> Repo.insert!()

    assert Operations.next_agent_action_candidate().id == priority.id
    assert Enum.map(Operations.list_queued_agent_actions(), & &1.id) == [priority.id, ordinary.id]
    assert Operations.repository_merge_locked?(repository.id)
  end

  test "a priority merge waiting for active repository work does not starve another repository" do
    busy_repository = repository_fixture()
    busy_issue = issue_fixture(busy_repository)
    proposal_fixture(busy_issue)
    {:ok, busy_job} = Operations.approve_issue(busy_issue.id, "andreas")

    busy_job
    |> PtcManager.Operations.Job.changeset(%{state: "working"})
    |> Repo.update!()

    other_repository = repository_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: busy_repository.id,
      action_key: "repair_and_merge_pr",
      target_type: "pull_request",
      target_id: 9_101,
      target_label: "busy/repo#9101",
      prompt_version: 1,
      prompt: "Fix and merge",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "andreas",
      state: "queued",
      attempt_count: 0,
      requested_at: DateTime.add(now, -60, :second)
    })
    |> Repo.insert!()

    available =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: other_repository.id,
        action_key: "prepare_issue",
        target_type: "issue",
        target_id: 9_102,
        target_label: "other/repo#9102",
        prompt_version: 1,
        prompt: "Prepare issue",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "andreas",
        state: "queued",
        attempt_count: 0,
        requested_at: now
      })
      |> Repo.insert!()

    assert Operations.next_agent_action_candidate().id == available.id
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
      remote_base_sha: String.duplicate("d", 40),
      published_at: DateTime.utc_now(),
      pr_state: "merged",
      source: "broker"
    })
    |> Repo.insert!()
  end

  defp open_publication_fixture(issue) do
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    job
    |> PtcManager.Operations.Job.changeset(%{
      state: "pr_open",
      branch_name: "ptc/issue-#{issue.number}",
      result_base_sha: String.duplicate("a", 40),
      result_head_sha: String.duplicate("b", 40),
      result_diff_digest: String.duplicate("c", 64),
      result_commit_count: 1,
      result_verified_at: now
    })
    |> Repo.update!()

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      state: "published",
      idempotency_key:
        :crypto.hash(:sha256, "open-publication-#{issue.id}")
        |> Base.encode16(case: :lower),
      fencing_token: job.fencing_token,
      branch_name: "ptc/issue-#{issue.number}",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: 80 + issue.number,
      pr_url: "https://github.com/example/repo/pull/#{80 + issue.number}",
      remote_head_sha: String.duplicate("b", 40),
      published_at: now,
      pr_state: "open",
      pr_checked_at: now,
      source: "broker"
    })
    |> Repo.insert!()
  end

  defp merge_status(publication, repository) do
    %{
      pr_number: publication.pr_number,
      pr_url: publication.pr_url,
      state: "open",
      draft: false,
      body: "Fixes the retry bug.",
      head_sha: publication.remote_head_sha,
      head_ref: publication.branch_name,
      head_repository: "#{repository.github_owner}/#{repository.github_name}",
      base_sha: String.duplicate("d", 40),
      base_ref: repository.default_branch,
      base_repository: "#{repository.github_owner}/#{repository.github_name}"
    }
  end

  defp retain_repair_worktree(publication) do
    worker = worker_fixture(%{worker_key: "repair-worker-#{publication.id}"})

    %WorktreeAllocation{}
    |> WorktreeAllocation.changeset(%{
      worker_id: worker.id,
      job_id: publication.job_id,
      state: "reclaimable",
      path: System.tmp_dir!(),
      head_sha: publication.remote_head_sha,
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()
  end

  defp enqueue_legacy_retrospective(publication, actor) do
    publication =
      Repo.preload(publication, [:repository, job: [:issue, :repository, :worktree_allocation]])

    repository = publication.repository || publication.job.repository

    with {:ok, attrs} <-
           Catalog.build("pr_retrospective", %{
             publication: publication,
             issue: publication.job.issue,
             repository: repository
           }) do
      Operations.enqueue_agent_action(
        Map.merge(attrs, %{action_key: "pr_retrospective", actor: actor})
      )
    end
  end

  defp retain_real_repair_worktree(publication, issue) do
    path =
      Path.join(System.tmp_dir!(), "ptc-manager-repair-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(path, "README.md"), "published\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "published head"])
    branch = "ptc-manager/issue-#{issue.number}-job-#{publication.job_id}"
    git!(path, ["switch", "-c", branch])

    job = Repo.get!(PtcManager.Operations.Job, publication.job_id)
    job |> PtcManager.Operations.Job.changeset(%{branch_name: branch}) |> Repo.update!()

    worker = worker_fixture(%{worker_key: "real-repair-worker-#{publication.id}"})

    %WorktreeAllocation{}
    |> WorktreeAllocation.changeset(%{
      worker_id: worker.id,
      job_id: publication.job_id,
      state: "reclaimable",
      path: path,
      head_sha: git!(path, ["rev-parse", "HEAD"]) |> String.trim(),
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.insert!()
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    output
  end
end
