defmodule PtcManager.AutoImplementationTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.{AutoImplementation, Operations}
  alias PtcManager.Operations.{Approval, AuditEvent, Issue, Job}

  defmodule PullClient do
    def list_open(_repository), do: Process.get(:auto_fix_pulls, {:ok, []})
  end

  defmodule IssueClient do
    def list_open_issues(_repository), do: Process.get(:auto_fix_remote)
    def get_issue(_repository, _number), do: Process.get(:auto_fix_remote_single)
  end

  setup do
    previous = Application.fetch_env!(:ptc_manager, :pull_request_client)
    Application.put_env(:ptc_manager, :pull_request_client, PullClient)
    on_exit(fn -> Application.put_env(:ptc_manager, :pull_request_client, previous) end)
    :ok
  end

  test "configuration handles a repository removed before the event arrives" do
    repository = repository_fixture()
    Repo.delete!(repository)

    assert {:error, :repository_not_found} =
             AutoImplementation.configure(repository.id, true, "andreas")

    refute Repo.exists?(
             from event in AuditEvent, where: event.action == "repository.auto_fix_updated"
           )
  end

  test "queued, running and synchronizing issue actions defer automatic admission" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    {:ok, action} = PtcManager.MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")

    for state <- ["queued", "running", "sync_pending"] do
      Repo.update_all(from(a in PtcManager.Operations.AgentAction, where: a.id == ^action.id),
        set: [state: state]
      )

      assert {:error, :issue_action_active} = Operations.auto_approve_issue(issue.id)
    end

    assert Repo.aggregate(Job, :count) == 0
  end

  test "disabled by default, explicitly enabled per repository and audited" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    assert AutoImplementation.reconcile(repository.id) == []
    assert {:error, :auto_fix_disabled} = Operations.auto_approve_issue(issue.id)
    assert {:ok, enabled} = AutoImplementation.configure(repository.id, true, "andreas")
    assert enabled.auto_fix_issues
    assert Repo.get_by!(AuditEvent, action: "repository.auto_fix_updated").actor == "andreas"
    assert [{:ok, job}] = AutoImplementation.reconcile(repository.id)
    assert job.execution_settings["name"] == "standard"
    assert Repo.get!(Approval, job.approval_id).decision == "start_implementation_automatic"
  end

  test "uses existing complexity profiles and consumes eligibility even after failure and label toggles" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    proposal_fixture(issue, %{scope: "large", risk: "high"})
    assert {:ok, job} = Operations.auto_approve_issue(issue.id)
    assert job.execution_settings["name"] == "strong"
    assert {:error, :already_attempted} = Operations.auto_approve_issue(issue.id)
    job |> Job.changeset(%{state: "failed"}) |> Repo.update!()
    issue |> Issue.changeset(%{workflow_label: nil}) |> Repo.update!()
    assert AutoImplementation.reconcile(repository.id) == []
    Repo.reload!(issue) |> Issue.changeset(%{workflow_label: "ptc:ready"}) |> Repo.update!()
    assert [{:error, :already_attempted}] = AutoImplementation.reconcile(repository.id)
    assert Repo.aggregate(Job, :count) == 1
    assert {:ok, _manual_retry} = Operations.approve_issue_directly(issue.id, "andreas")
  end

  test "does not reuse a stale complexity assessment" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    proposal_fixture(issue, %{scope: "large", source_digest: "outdated"})
    assert {:ok, job} = Operations.auto_approve_issue(issue.id)
    assert job.execution_settings["name"] == "standard"
    assert Repo.get!(Approval, job.approval_id).proposal_id == nil
  end

  test "rejects closed, assigned, conflicting, blocked and unprojected issues" do
    repository = repository_fixture(%{auto_fix_issues: true})

    for attrs <- [
          %{state: "closed"},
          %{github_assignees: %{"logins" => ["someone"]}},
          %{workflow_label_conflict: true},
          %{workflow_label: "ptc:blocked"},
          %{workflow_label: nil},
          %{dependencies_projected: false},
          %{github_assignment_projected: false}
        ] do
      issue = issue_fixture(repository, Map.merge(%{workflow_label: "ptc:ready"}, attrs))
      assert {:error, _reason} = Operations.auto_approve_issue(issue.id)
    end

    assert Repo.aggregate(Job, :count) == 0
  end

  test "unresolved native dependencies prevent admission and automatic eligibility" do
    repository = repository_fixture(%{auto_fix_issues: true})
    blocker = issue_fixture(repository)
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})

    issue_dependency_fixture(issue, %{
      blocking_issue: blocker,
      blocking_repository: repository
    })

    assert AutoImplementation.reconcile(repository.id) == []
    assert {:error, :issue_dependencies_unresolved} = AutoImplementation.eligible(Repo, issue)
    assert {:error, :issue_dependencies_unresolved} = Operations.auto_approve_issue(issue.id)
  end

  test "dependency projection failures and explicit holds prevent admission" do
    repository = repository_fixture(%{auto_fix_issues: true})

    for attrs <- [
          %{dependencies_projected: false},
          %{dependency_overflow: true},
          %{dependency_unknown_count: 1}
        ] do
      issue = issue_fixture(repository, Map.merge(%{workflow_label: "ptc:ready"}, attrs))
      assert AutoImplementation.reconcile(repository.id, issue.number) == []
    end

    held = issue_fixture(repository, %{workflow_label: "ptc:blocked"})

    issue_dependency_fixture(held, %{
      blocking_repository: repository,
      blocking_issue_number: 919,
      blocking_state: "closed",
      blocking_state_reason: "completed"
    })

    assert AutoImplementation.reconcile(repository.id, held.number) == []

    assert Repo.aggregate(Job, :count) == 0
  end

  test "repository sync admits a ready dependent after its native blocker completes" do
    repository =
      repository_fixture(%{
        auto_fix_issues: true,
        github_owner: "example",
        github_name: "project"
      })

    blocker = remote_issue(920, "Build the prerequisite", "open", nil)

    dependent =
      remote_issue(921, "Use the prerequisite", "open", nil)
      |> Map.put("blocked_by", [native_blocker(blocker)])

    Process.put(:auto_fix_remote, {:ok, [blocker, dependent]})
    assert {:ok, _} = PtcManager.GitHub.Sync.sync_repository(repository, client: IssueClient)

    assert [%Job{issue_id: first_issue_id}] = Repo.all(Job)
    assert Repo.get_by!(Issue, repository_id: repository.id, number: 920).id == first_issue_id

    completed = remote_issue(920, "Build the prerequisite", "closed", "completed")
    dependent = Map.put(dependent, "blocked_by", [native_blocker(completed)])
    Process.put(:auto_fix_remote, {:ok, [dependent]})
    Process.put(:auto_fix_remote_single, {:ok, completed})

    assert {:ok, _} = PtcManager.GitHub.Sync.sync_repository(repository, client: IssueClient)
    dependent_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 921)
    assert dependent_issue.workflow_label == "ptc:ready"
    assert Repo.get_by!(Job, issue_id: dependent_issue.id)
  end

  test "a blocker closed as not planned does not admit its ready dependent" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})

    issue_dependency_fixture(issue, %{
      blocking_repository: repository,
      blocking_issue_number: 930,
      blocking_state: "closed",
      blocking_state_reason: "not_planned"
    })

    assert AutoImplementation.reconcile(repository.id) == []
  end

  test "daily budget survives failed jobs and applies across synchronizations" do
    repository = repository_fixture(%{auto_fix_issues: true})
    for _ <- 1..6, do: issue_fixture(repository, %{workflow_label: "ptc:ready"})
    results = AutoImplementation.reconcile(repository.id)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 5
    assert {:error, :auto_fix_daily_limit} in results
    Repo.update_all(Job, set: [state: "failed"])
    assert {:error, :auto_fix_daily_limit} in AutoImplementation.reconcile(repository.id)
    assert Repo.aggregate(Job, :count) == 5
  end

  test "does not admit work when pull request discovery fails" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue_fixture(repository, %{workflow_label: "ptc:ready"})
    Process.put(:auto_fix_pulls, {:error, :unavailable})

    assert [{:error, {:pull_requests_unavailable, _}}] =
             AutoImplementation.reconcile(repository.id)

    assert Repo.aggregate(Job, :count) == 0
  end

  test "discovers an external PR before admission and does not restart after it closes" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})

    pull =
      external_pr_status(repository, 900, String.duplicate("b", 40))
      |> Map.put(:body, "Closes ##{issue.number}")

    Process.put(:auto_fix_pulls, {:ok, [pull]})
    assert [{:error, :issue_has_pull_request}] = AutoImplementation.reconcile(repository.id)
    Repo.update_all(PtcManager.Operations.PrPublication, set: [pr_state: "closed"])
    Process.put(:auto_fix_pulls, {:ok, []})
    assert [{:error, :issue_has_pull_request}] = AutoImplementation.reconcile(repository.id)
    assert Repo.aggregate(Job, :count) == 0
  end

  test "a new UTC day admits the remaining backlog without restarting old jobs" do
    repository = repository_fixture(%{auto_fix_issues: true})
    for _ <- 1..6, do: issue_fixture(repository, %{workflow_label: "ptc:ready"})
    AutoImplementation.reconcile(repository.id)

    Repo.update_all(Approval,
      set: [approved_at: DateTime.add(DateTime.utc_now(), -86_400, :second)]
    )

    results = AutoImplementation.reconcile(repository.id)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Repo.aggregate(Job, :count) == 6
  end

  test "a collection, an unknown structure, and a fresh breakdown request are never admitted" do
    repository = repository_fixture(%{auto_fix_issues: true})

    collection =
      issue_fixture(repository, %{
        workflow_label: "ptc:ready",
        sub_issues: %{
          "nodes" => [
            %{
              "number" => 2,
              "state" => "open",
              "state_reason" => nil,
              "repository_full_name" => "owner/repo"
            }
          ],
          "total" => 1
        }
      })

    unknown =
      issue_fixture(repository, %{workflow_label: "ptc:ready", structure_projected: false})

    breakdown = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    proposal_fixture(breakdown, %{readiness: "needs_breakdown", scope: "large"})

    assert {:error, :issue_is_collection} = Operations.auto_approve_issue(collection.id)
    assert {:error, :issue_structure_unknown} = Operations.auto_approve_issue(unknown.id)
    assert {:error, :issue_needs_breakdown} = Operations.auto_approve_issue(breakdown.id)
    assert AutoImplementation.reconcile(repository.id) == [{:error, :issue_needs_breakdown}]
    assert Repo.aggregate(Job, :count) == 0

    # A stale breakdown request keeps today's fallback, and a maintainer may
    # always decide by hand.
    Repo.reload!(breakdown)
    |> Issue.changeset(%{content_digest: digest("edited")})
    |> Repo.update!()

    assert {:ok, _job} = Operations.auto_approve_issue(breakdown.id)

    assert {:error, :issue_is_collection} =
             Operations.approve_issue_directly(collection.id, "andreas")

    remote = %{
      workflow_label: "ptc:ready",
      workflow_label_conflict: false,
      structure_projected: true,
      sub_issues: %{"nodes" => [], "total" => 1},
      github_assignees: %{"logins" => []}
    }

    job = %Job{
      approval: %Approval{decision: "start_implementation_automatic"},
      repository: repository,
      issue: collection
    }

    assert {:error, :issue_is_collection} = AutoImplementation.dispatch_allowed(job, remote)

    assert {:error, :issue_structure_unknown} =
             AutoImplementation.dispatch_allowed(job, %{remote | structure_projected: false})
  end

  test "successful synchronization triggers admission once, including a newly applied ready label" do
    repository = repository_fixture(%{auto_fix_issues: true})

    remote = %{
      "number" => 910,
      "title" => "Fix it",
      "body" => "A bounded change",
      "html_url" => "https://github.com/example/repo/issues/910",
      "state" => "open",
      "updated_at" => "2026-09-06T08:00:00Z",
      "labels" => [],
      "parent" => nil,
      "sub_issues" => %{"nodes" => [], "total" => 0, "overflow" => false},
      "structure_projected" => true
    }

    Process.put(:auto_fix_remote, {:ok, [remote]})
    assert {:ok, _} = PtcManager.GitHub.Sync.sync_repository(repository, client: IssueClient)
    assert Repo.aggregate(Job, :count) == 0
    ready = %{remote | "labels" => [%{"name" => "ptc:ready"}]}
    Process.put(:auto_fix_remote_single, {:ok, ready})
    assert {:ok, _} = PtcManager.GitHub.Sync.sync_issue(repository, 910, client: IssueClient)
    Process.put(:auto_fix_remote, {:ok, [ready]})
    assert {:ok, _} = PtcManager.GitHub.Sync.sync_repository(repository, client: IssueClient)
    assert Repo.aggregate(Job, :count) == 1
  end

  test "failed synchronization does not admit cached ready issues" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue_fixture(repository, %{workflow_label: "ptc:ready"})
    Process.put(:auto_fix_remote, {:error, :unavailable})

    assert {:error, :unavailable} =
             PtcManager.GitHub.Sync.sync_repository(repository, client: IssueClient)

    assert Repo.aggregate(Job, :count) == 0
  end

  test "concurrent admissions create just one job and approval" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})

    results =
      1..4
      |> Enum.map(fn _ -> Task.async(fn -> Operations.auto_approve_issue(issue.id) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_attempted})) == 3
    assert Repo.aggregate(Approval, :count) == 1
    assert Repo.aggregate(Job, :count) == 1
  end

  test "single-issue sync admission does not use other cached issues" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    issue_fixture(repository, %{workflow_label: "ptc:ready"})
    assert [{:ok, job}] = AutoImplementation.reconcile(repository.id, issue.number)
    assert job.issue_id == issue.id
  end

  test "disabling prevents an automatic queued job from dispatching" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    {:ok, job} = Operations.auto_approve_issue(issue.id)
    {:ok, _} = AutoImplementation.configure(repository.id, false, "andreas")
    job = Repo.preload(job, [:approval, :repository, :issue], force: true)
    assert {:error, :auto_fix_disabled} = AutoImplementation.dispatch_allowed(job, issue)
  end

  test "dispatch rechecks ready label and assignment even if the stored digest matches" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})
    {:ok, job} = Operations.auto_approve_issue(issue.id)
    job = Repo.preload(job, [:approval, :repository, :issue])
    remote = issue |> Map.from_struct() |> Map.put(:blocking_issues, [])
    assert :ok = AutoImplementation.dispatch_allowed(job, remote)

    assert {:error, :issue_workflow_not_ready} =
             AutoImplementation.dispatch_allowed(job, %{remote | workflow_label: nil})

    assert {:error, :issue_claimed} =
             AutoImplementation.dispatch_allowed(job, %{
               remote
               | github_assignees: %{"logins" => ["other"]}
             })
  end

  test "dispatch refuses when a completed native blocker is reopened remotely" do
    repository = repository_fixture(%{auto_fix_issues: true})
    issue = issue_fixture(repository, %{workflow_label: "ptc:ready"})

    issue_dependency_fixture(issue, %{
      blocking_repository: repository,
      blocking_issue_number: 999,
      blocking_state: "closed",
      blocking_state_reason: "completed"
    })

    {:ok, job} = Operations.auto_approve_issue(issue.id)
    job = Repo.preload(job, [:approval, :repository, :issue])

    remote =
      issue
      |> Map.from_struct()
      |> Map.put(:blocking_issues, [
        %{
          repository_full_name:
            String.downcase("#{repository.github_owner}/#{repository.github_name}"),
          number: 999,
          state: "open",
          state_reason: nil
        }
      ])

    assert {:error, :issue_dependencies_unresolved} =
             AutoImplementation.dispatch_allowed(job, remote)
  end

  defp remote_issue(number, title, state, state_reason) do
    %{
      "number" => number,
      "title" => title,
      "html_url" => "https://github.com/example/project/issues/#{number}",
      "body" => "Issue body #{number}",
      "state" => state,
      "state_reason" => state_reason,
      "updated_at" => "2026-09-18T09:21:00Z",
      "labels" => [%{"name" => "ptc:ready"}],
      "parent" => nil,
      "sub_issues" => %{"nodes" => [], "total" => 0, "overflow" => false},
      "structure_projected" => true
    }
  end

  defp native_blocker(blocker) do
    blocker
    |> Map.put("id", blocker["number"] + 10_000)
    |> Map.put("node_id", "ISSUE_#{blocker["number"]}")
    |> Map.put("repository", %{"full_name" => "example/project"})
  end
end
