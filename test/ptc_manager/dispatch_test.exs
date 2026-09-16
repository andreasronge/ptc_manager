defmodule PtcManager.DispatchTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Dispatch
  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AgentRun, AuditEvent, Job}
  alias PtcManager.Repo

  defmodule FakeGitHub do
    @behaviour PtcManager.GitHub
    def list_open_issues(_repository), do: {:ok, []}
    def get_issue(_repository, _number), do: Process.get(:dispatch_github_result)
  end

  defmodule FakeAdapter do
    @behaviour PtcManager.Dispatch.Adapter

    def dispatch(context) do
      send(Process.get(:dispatch_test_pid), {:dispatch_context, context})
      Process.get(:dispatch_adapter_result)
    end

    def remove_worktree(_allocation), do: :ok
  end

  defmodule FakeWorkspaceSetup do
    def run(_path, _job), do: Process.get(:workspace_setup_result) || {:ok, report()}

    def report(attrs \\ %{}) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      Map.merge(
        %{
          state: "passed",
          script: "scripts/ptc/setup-worktree",
          source_sha: String.duplicate("a", 40),
          started_at: now,
          ended_at: now,
          duration_ms: 42,
          exit_status: 0,
          output: "ready\n",
          output_truncated: false,
          cache_state: nil,
          phase_durations: %{},
          error: nil
        },
        attrs
      )
    end
  end

  defmodule FailingSourceUpdater do
    def refresh(_repository), do: {:error, :repository_source_refresh_failed}
  end

  defmodule IssueChangingSourceUpdater do
    def refresh(repository) do
      {:ok, remote} = Process.get(:dispatch_github_result)

      Process.put(
        :dispatch_github_result,
        {:ok, Map.put(remote, "title", "Changed during fetch")}
      )

      PtcManager.TestSourceUpdater.refresh(repository)
    end
  end

  setup do
    Process.put(:dispatch_test_pid, self())

    {:ok, _worker} =
      Operations.create_worker(%{
        worker_key: "herdr:default",
        name: "Herdr default",
        status: "online",
        capabilities: %{"herdr" => true, "implementation_slots" => 1},
        coordinator_incarnation_id: PtcManager.RuntimeIncarnation.current()
      })

    Process.put(
      :dispatch_adapter_result,
      {:ok,
       %{
         workspace_id: "w-job",
         pane_id: "w-job:p1",
         session: "default",
         external_key: "default:w-job:p1",
         agent_name: "impl_j1_f1"
       }}
    )

    :ok
  end

  test "leaves work queued when the synchronized worker is degraded" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    worker = Repo.get_by!(Operations.Worker, worker_key: "herdr:default")
    worker |> Operations.Worker.changeset(%{status: "degraded"}) |> Repo.update!()

    assert {:error, :worker_unavailable} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "queued merge work prevents lower-priority implementation from starting" do
    {repository, _issue, _proposal, job, remote} = approved_job_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "repair_and_merge_pr",
      target_type: "pull_request",
      target_id: 9_003,
      target_label: "example/repo#9003",
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

    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:ok, :empty} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "queued repair work prevents lower-priority implementation from starting" do
    {repository, _issue, _proposal, job, remote} = approved_job_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "repair_pr",
      target_type: "pull_request",
      target_id: 9_004,
      target_label: "example/repo#9004",
      prompt_version: 1,
      prompt: "Repair the exact pull request",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "andreas",
      state: "queued",
      attempt_count: 0,
      requested_at: now
    })
    |> Repo.insert!()

    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:ok, :empty} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)
    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "fresh approved work is leased once and attached to a fenced Herdr attempt" do
    {repository, issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:ok, %{job: working, run: run}} =
             Dispatch.run_once(
               github: FakeGitHub,
               adapter: FakeAdapter,
               worker_key: "herdr:default",
               lease_ms: 60_000
             )

    assert_receive {:dispatch_context, %{job: leased, source: source}}
    assert source.sha == String.duplicate("a", 40)
    assert source.ref == "refs/heads/main"
    assert leased.id == job.id
    assert leased.state == "starting"
    assert leased.fencing_token == 1
    assert leased.branch_name == "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    assert leased.publication_source == "broker"

    assert working.state == "working"
    assert working.repository_id == repository.id
    assert run.job_id == job.id
    assert run.fencing_token == 1
    assert run.agent_name == "impl_j1_f1"
    assert run.herdr_workspace == "w-job"
    assert run.herdr_pane == "w-job:p1"
    assert Repo.aggregate(AgentRun, :count) == 1

    actions = Repo.all(from audit in AuditEvent, select: audit.action)
    assert "job.leased" in actions
    assert "job.started" in actions
  end

  test "a failed default-branch refresh leaves approved work queued" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:error, :repository_source_refresh_failed} =
             Dispatch.run_once(
               github: FakeGitHub,
               adapter: FakeAdapter,
               source_updater: FailingSourceUpdater
             )

    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "persists workspace setup evidence before marking the agent working" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    report =
      FakeWorkspaceSetup.report(%{
        duration_ms: 3_742,
        cache_state: "hit",
        phase_durations: %{"dependencies_ms" => 900}
      })

    Process.put(
      :dispatch_adapter_result,
      {:ok,
       %{
         workspace_id: "w-job",
         pane_id: "w-job:p1",
         session: "default",
         external_key: "default:w-job:p1",
         agent_name: "impl_j1_f1",
         workspace_setup: Map.put(report, :worktree_created_duration_ms, 123)
       }}
    )

    assert {:ok, %{job: %{state: "working"}}} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    allocation = Repo.get_by!(Operations.WorktreeAllocation, job_id: job.id)
    assert allocation.workspace_setup_state == "passed"
    assert allocation.workspace_setup_script == "scripts/ptc/setup-worktree"
    assert allocation.workspace_setup_source_sha == String.duplicate("a", 40)
    assert allocation.worktree_created_duration_ms == 123
    assert allocation.workspace_setup_duration_ms == 3_742
    assert allocation.workspace_setup_exit_status == 0
    assert allocation.workspace_setup_output == "ready\n"
    assert allocation.workspace_setup_cache_state == "hit"
    assert allocation.workspace_setup_phase_durations == %{"dependencies_ms" => 900}
  end

  test "a recorded setup failure ends the job without creating an agent run" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    report =
      FakeWorkspaceSetup.report(%{
        state: "failed",
        exit_status: 17,
        output: "missing tool\n",
        error: :workspace_setup_failed,
        worktree_created_duration_ms: 91
      })

    Process.put(
      :dispatch_adapter_result,
      {:error, {:safe, {:workspace_setup_failed, report}}}
    )

    assert {:error, :workspace_setup_failed} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    failed = Repo.get!(Job, job.id)
    allocation = Repo.get_by!(Operations.WorktreeAllocation, job_id: job.id)
    assert failed.state == "failed"
    assert allocation.state == "removed"
    assert allocation.workspace_setup_state == "failed"
    assert allocation.workspace_setup_exit_status == 17
    assert allocation.workspace_setup_output == "missing tool\n"
    assert Repo.aggregate(AgentRun, :count) == 0
  end

  test "a definitive worktree creation failure ends the job with Git's explanation" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    git_error =
      "Preparing worktree (new branch 'ptc-manager/issue-2-job-27')\n" <>
        "fatal: cannot lock ref 'refs/heads/ptc-manager/issue-2-job-27': " <>
        "unable to create directory for .git/refs/heads/ptc-manager/issue-2-job-27"

    Process.put(
      :dispatch_adapter_result,
      {:error, {:safe, {:worktree_create_failed, git_error}}}
    )

    assert {:error, {:worktree_create_failed, ^git_error}} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    failed = Repo.get!(Job, job.id)
    allocation = Repo.get_by!(Operations.WorktreeAllocation, job_id: job.id)
    assert failed.state == "failed"
    assert failed.ended_at
    assert failed.last_error =~ "Herdr could not create the job worktree"
    assert failed.last_error =~ "cannot lock ref"
    refute failed.last_error =~ "\\n"
    assert allocation.state == "removed"
    assert Repo.aggregate(AgentRun, :count) == 0

    actions = Repo.all(from audit in AuditEvent, select: audit.action)
    assert "job.dispatch_failed" in actions
    refute "job.dispatch_uncertain" in actions
  end

  test "a changed GitHub issue cancels the approval before dispatch, in words" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    changed = Map.put(remote, "title", "Changed after approval")
    Process.put(:dispatch_github_result, {:ok, changed})

    assert {:error, :issue_changed} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    refute_receive {:dispatch_context, _context}
    rejected = Repo.get!(Job, job.id)
    assert rejected.state == "cancelled"
    assert rejected.fencing_token == 0
    assert rejected.last_error =~ "title or body changed"

    assert %{details: %{"reason" => "issue_changed"}} =
             Repo.get_by!(AuditEvent, action: "job.dispatch_rejected", target_id: job.id)
  end

  test "a comment after approval re-freezes the approval instead of cancelling the job" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    commented = Map.put(remote, "updated_at", "2026-08-29T10:30:00Z")
    Process.put(:dispatch_github_result, {:ok, commented})

    assert {:ok, _summary} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)
    assert_receive {:dispatch_context, _context}

    leased = Repo.get!(Job, job.id) |> Repo.preload(:approval)
    assert leased.state in ["starting", "working"]
    assert leased.approval.source_updated_at == ~U[2026-08-29 10:30:00.000000Z]

    assert %{details: %{"approval_id" => approval_id}} =
             Repo.get_by!(AuditEvent, action: "approval.refrozen", target_id: job.id)

    assert approval_id == leased.approval.id
  end

  test "a changed body refuses dispatch in words" do
    refuse_dispatch!(
      %{"body" => "Rewritten requirement."},
      :issue_changed,
      "title or body changed"
    )
  end

  test "a label that no longer says ready refuses dispatch" do
    refuse_dispatch!(
      %{"labels" => [%{"name" => "ptc:blocked"}]},
      :issue_workflow_not_ready,
      "no longer carries the ready label"
    )
  end

  test "an assignment to someone else refuses dispatch" do
    refuse_dispatch!(
      %{"assignees" => [%{"login" => "someone-else"}]},
      :issue_claimed,
      "assigned to someone else"
    )
  end

  test "sub-issues that make the issue a collection refuse dispatch" do
    refuse_dispatch!(
      %{"sub_issues" => %{"nodes" => [%{"number" => 999, "state" => "open"}], "total" => 1}},
      :issue_is_collection,
      "sub-issues"
    )
  end

  test "a job approved without a snapshot keeps the strict rule" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [execution_settings: nil])

    Process.put(
      :dispatch_github_result,
      {:ok, Map.put(remote, "updated_at", "2026-08-29T10:30:00Z")}
    )

    assert {:error, :issue_changed} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)
    assert Repo.get!(Job, job.id).state == "cancelled"
  end

  test "rechecks approval after a source fetch that overlaps an issue edit" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:error, :issue_changed} =
             Dispatch.run_once(
               github: FakeGitHub,
               adapter: FakeAdapter,
               source_updater: IssueChangingSourceUpdater
             )

    refute_receive {:dispatch_context, _}
    assert Repo.get!(Job, job.id).state == "cancelled"
  end

  test "an unresolved dependency cancels a queued job before agent dispatch" do
    {repository, issue, _proposal, job, remote} = approved_job_fixture()
    blocker = issue_fixture(repository, %{number: issue.number + 1})

    issue_dependency_fixture(issue, %{
      blocking_issue: blocker,
      blocking_repository: repository
    })

    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:error, :issue_dependencies_unresolved} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    refute_receive {:dispatch_context, _context}
    assert Repo.get!(Job, job.id).state == "cancelled"
  end

  test "dispatch does not treat dependency prose as the machine-readable contract" do
    repository = repository_fixture()

    remote =
      remote_issue(System.unique_integer([:positive])) |> Map.put("body", "Blocked by #999")

    issue = issue_fixture(repository, IssueSnapshot.normalize!(remote, repository.id))
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:ok, %{job: working}} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    assert_receive {:dispatch_context, _context}
    assert working.id == job.id
  end

  test "a GitHub read failure leaves the approved job queued" do
    {_repository, _issue, _proposal, job, _remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:error, :offline})

    assert {:error, :offline} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)
    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "an ambiguous Herdr launch failure blocks retries pending reconciliation" do
    {repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})
    Process.put(:dispatch_adapter_result, {:error, :agent_not_ready})

    assert {:error, :agent_not_ready} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    uncertain = Repo.get!(Job, job.id)
    assert uncertain.state == "reconciling"
    assert uncertain.fencing_token == 1
    assert uncertain.last_error =~ "agent_not_ready"
    refute uncertain.ended_at

    second_remote = remote_issue(System.unique_integer([:positive]))

    second_issue =
      issue_fixture(repository, IssueSnapshot.normalize!(second_remote, repository.id))

    proposal_fixture(second_issue)
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "andreas")

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(second_remote, repository.id),
               60_000
             )

    assert Repo.get!(Job, second_job.id).state == "queued"

    job
    |> Job.changeset(%{state: "idle"})
    |> Repo.update!()

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(second_remote, repository.id),
               60_000
             )
  end

  test "a second lease contender cannot cancel the first lease" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    canonical = IssueSnapshot.normalize!(remote, job.repository_id)

    assert {:ok, leased} = Operations.lease_job(job.id, "herdr:default", canonical, 60_000)

    assert {:error, :already_leased} =
             Operations.lease_job(job.id, "herdr:default", canonical, 60_000)

    current = Repo.get!(Job, job.id)
    assert current.state == "starting"
    assert current.fencing_token == leased.fencing_token
  end

  test "transactional capacity leaves additional approved work queued" do
    {repository, _issue, _proposal, first_job, first_remote} = approved_job_fixture()
    second_remote = remote_issue(System.unique_integer([:positive]))

    second_issue =
      issue_fixture(repository, IssueSnapshot.normalize!(second_remote, repository.id))

    proposal_fixture(second_issue)
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "andreas")

    assert {:ok, _leased} =
             Operations.lease_job(
               first_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(first_remote, repository.id),
               60_000
             )

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(second_remote, repository.id),
               60_000
             )

    assert Repo.get!(Job, second_job.id).state == "queued"
  end

  test "an expired lease stays active for reconciliation instead of enabling a duplicate" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    canonical = IssueSnapshot.normalize!(remote, job.repository_id)
    assert {:ok, leased} = Operations.lease_job(job.id, "herdr:default", canonical, 1)

    later = DateTime.add(leased.lease_expires_at, 1, :second)
    assert Operations.expire_job_leases(later) == 1

    reconciling = Repo.get!(Job, job.id)
    assert reconciling.state == "reconciling"
    assert {:error, :already_active} = Operations.approve_issue(job.issue_id, "andreas")
  end

  test "an unsafe worktree root leaves implementation work queued" do
    unique = System.unique_integer([:positive, :monotonic])
    unsafe_root = Path.join(System.tmp_dir!(), "ptc-manager-unsafe-root-#{unique}")
    File.mkdir_p!(unsafe_root)
    File.chmod!(unsafe_root, 0o750)

    keys = [:worktree_root, :worktree_permission_check, :worktree_owner_uid]
    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf!(unsafe_root)
    end)

    Application.put_env(:ptc_manager, :worktree_root, unsafe_root)
    Application.put_env(:ptc_manager, :worktree_permission_check, true)
    Application.put_env(:ptc_manager, :worktree_owner_uid, File.stat!(unsafe_root).uid)

    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    canonical = IssueSnapshot.normalize!(remote, job.repository_id)

    assert {:error, reason} = Operations.lease_job(job.id, "herdr:default", canonical, 60_000)
    assert PtcManager.WorktreeSecurity.infrastructure_error?(reason)
    assert Repo.get!(Job, job.id).state == "queued"
  end

  test "a lease records the agent kind frozen by the execution profile" do
    put_agent_profiles(%{
      "codex" => %{"enabled" => true, "args" => []},
      "cursor" => %{"enabled" => true, "args" => ["--force", "--trust"]}
    })

    repository = repository_fixture(%{local_path: "/tmp/repository"})

    {:ok, _} =
      PtcManager.ExecutionProfiles.save(
        "small",
        %{"kind" => "cursor", "model" => "cursor-grok-4.6-high"},
        "maintainer"
      )

    {_repository, _issue, _proposal, job, remote} = approved_job_fixture(repository)
    canonical = IssueSnapshot.normalize!(remote, repository.id)

    assert {:ok, leased} = Operations.lease_job(job.id, "herdr:default", canonical, 60_000)
    assert leased.worktree_allocation.agent_kind == "cursor"

    audit = Repo.get_by!(AuditEvent, action: "job.leased", target_type: "job", target_id: job.id)
    assert audit.details["agent_kind"] == "cursor"
  end

  test "a lease cancels a job whose required agent kind has no enabled profile" do
    put_agent_profiles(%{
      "codex" => %{"enabled" => true, "args" => []},
      "cursor" => %{"enabled" => true, "args" => []}
    })

    repository = repository_fixture(%{local_path: "/tmp/repository"})

    {:ok, _} =
      PtcManager.ExecutionProfiles.save(
        "small",
        %{"kind" => "cursor", "model" => "cursor-grok-4.6-high"},
        "maintainer"
      )

    {_repository, _issue, _proposal, job, remote} = approved_job_fixture(repository)
    put_agent_profiles(%{"codex" => %{"enabled" => true, "args" => []}})
    canonical = IssueSnapshot.normalize!(remote, repository.id)

    assert {:error, :no_healthy_agent_profile} =
             Operations.lease_job(job.id, "herdr:default", canonical, 60_000)

    cancelled = Repo.get!(Job, job.id)
    assert cancelled.state == "cancelled"
    assert cancelled.last_error == "no_healthy_agent_profile"
  end

  test "decodes the documented Herdr worktree response" do
    output =
      Jason.encode!(%{
        "result" => %{
          "workspace" => %{"workspace_id" => "w12"},
          "root_pane" => %{"pane_id" => "w12:p1"}
        }
      })

    assert {:ok, "w12", "w12:p1"} = PtcManager.Dispatch.HerdrAdapter.decode_worktree(output)
  end

  test "Herdr worktree Git runs through the authorized worker helper" do
    previous_binary = Application.get_env(:ptc_manager, :herdr_git_binary)
    previous_user = Application.get_env(:ptc_manager, :herdr_run_as_user)

    on_exit(fn ->
      restore_env(:herdr_git_binary, previous_binary)
      restore_env(:herdr_run_as_user, previous_user)
    end)

    Application.put_env(
      :ptc_manager,
      :herdr_git_binary,
      "/usr/local/bin/ptc-manager-worker-git"
    )

    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")

    assert {"/usr/bin/sudo",
            [
              "-n",
              "-H",
              "-u",
              "ptc-manager-worker",
              "--",
              "/usr/local/bin/ptc-manager-worker-git",
              "-C",
              "/srv/ptc_runner",
              "rev-parse",
              "HEAD"
            ]} =
             PtcManager.Dispatch.HerdrAdapter.git_command_spec([
               "-C",
               "/srv/ptc_runner",
               "rev-parse",
               "HEAD"
             ])
  end

  test "terminal merged and closed PR worktrees use forced Herdr removal" do
    for {job_state, pr_state} <- [{"done", "merged"}, {"cancelled", "closed"}] do
      allocation = %{
        herdr_workspace: "w-terminal",
        job: %{state: job_state, pr_publication: %{pr_state: pr_state}}
      }

      assert PtcManager.Dispatch.HerdrAdapter.remove_worktree_args(allocation) == [
               "worktree",
               "remove",
               "--workspace",
               "w-terminal",
               "--force"
             ]
    end

    waiting = %{
      herdr_workspace: "w-waiting",
      job: %{state: "pr_open", pr_publication: %{pr_state: "open"}}
    }

    refute "--force" in PtcManager.Dispatch.HerdrAdapter.remove_worktree_args(waiting)
  end

  test "agent startup may outlive the generic Herdr command timeout" do
    unique = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "ptc-manager-slow-herdr-#{unique}")
    repository_path = Path.join(test_root, "repository")
    fake_herdr = Path.join(test_root, "herdr")

    File.mkdir_p!(repository_path)

    File.write!(
      fake_herdr,
      """
      #!/bin/sh
      case "$*" in
        *"worktree create"*)
          printf '%s' '{"result":{"workspace":{"workspace_id":"w-slow"},"root_pane":{"pane_id":"w-slow:p1"}}}'
          ;;
        *"agent start"*)
          sleep 1.5
          printf '%s' '{"result":{"agent":{"agent_session":{"value":"impl-slow"}}}}'
          ;;
        *"agent prompt"*)
          printf '%s' '{"result":{}}'
          ;;
        *)
          exit 2
          ;;
      esac
      """
    )

    File.chmod!(fake_herdr, 0o700)

    keys = [
      :dispatch_enabled,
      :herdr_binary,
      :herdr_run_as_user,
      :herdr_timeout_ms,
      :implementation_agent_start_timeout_ms,
      :workspace_setup
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)

      File.rm_rf!(test_root)
    end)

    Application.put_env(:ptc_manager, :herdr_binary, fake_herdr)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.delete_env(:ptc_manager, :herdr_run_as_user)
    Application.put_env(:ptc_manager, :herdr_timeout_ms, 1_000)
    Application.put_env(:ptc_manager, :implementation_agent_start_timeout_ms, 3_000)
    Application.put_env(:ptc_manager, :workspace_setup, FakeWorkspaceSetup)

    repository = repository_fixture(%{local_path: repository_path})
    remote = remote_issue(unique)
    issue = issue_fixture(repository, IssueSnapshot.normalize!(remote, repository.id))
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    assert {:ok, leased} =
             Operations.lease_job(
               job.id,
               "herdr:default",
               IssueSnapshot.normalize!(remote, repository.id),
               60_000
             )

    assert {:ok, dispatch} =
             PtcManager.Dispatch.HerdrAdapter.dispatch(%{
               job: leased,
               issue: leased.issue,
               repository: leased.repository,
               source: %{sha: String.duplicate("a", 40), ref: "refs/remotes/origin/main"}
             })

    assert dispatch.workspace_id == "w-slow"
    assert dispatch.pane_id == "w-slow:p1"
    assert dispatch.external_key == "default:impl-slow"
    assert dispatch.workspace_setup.duration_ms == 42
  end

  test "a known setup failure removes the Herdr worktree and never starts an agent" do
    unique = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "ptc-manager-setup-failure-#{unique}")
    repository_path = Path.join(test_root, "repository")
    fake_herdr = Path.join(test_root, "herdr")
    log = Path.join(test_root, "commands.log")
    File.mkdir_p!(repository_path)

    File.write!(
      fake_herdr,
      """
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{log}"
      case "$*" in
        *"worktree create"*)
          printf '%s' '{"result":{"workspace":{"workspace_id":"w-failed"},"root_pane":{"pane_id":"w-failed:p1"}}}'
          ;;
        *"worktree remove"*)
          printf '%s' '{"result":{}}'
          ;;
        *)
          exit 2
          ;;
      esac
      """
    )

    File.chmod!(fake_herdr, 0o700)

    keys = [:dispatch_enabled, :herdr_binary, :herdr_run_as_user, :workspace_setup]
    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      File.rm_rf!(test_root)
    end)

    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :herdr_binary, fake_herdr)
    Application.delete_env(:ptc_manager, :herdr_run_as_user)
    Application.put_env(:ptc_manager, :workspace_setup, FakeWorkspaceSetup)

    Process.put(
      :workspace_setup_result,
      {:error,
       FakeWorkspaceSetup.report(%{
         state: "failed",
         exit_status: 17,
         error: :workspace_setup_failed
       })}
    )

    repository = repository_fixture(%{local_path: repository_path})
    remote = remote_issue(unique)
    issue = issue_fixture(repository, IssueSnapshot.normalize!(remote, repository.id))
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    assert {:ok, leased} =
             Operations.lease_job(
               job.id,
               "herdr:default",
               IssueSnapshot.normalize!(remote, repository.id),
               60_000
             )

    assert {:error, {:safe, {:workspace_setup_failed, report}}} =
             PtcManager.Dispatch.HerdrAdapter.dispatch(%{
               job: leased,
               issue: leased.issue,
               repository: leased.repository,
               source: %{sha: String.duplicate("a", 40), ref: "refs/remotes/origin/main"}
             })

    assert report.exit_status == 17
    commands = File.read!(log)
    assert commands =~ "worktree create"
    assert commands =~ "worktree remove --workspace w-failed --force"
    refute commands =~ "agent start"
  end

  test "the default Codex profile uses the currently supported unattended flag" do
    assert ["--dangerously-bypass-approvals-and-sandbox" | _trust] =
             PtcManager.AgentProfiles.args("codex")
  end

  test "every agent kind starts on a named model rather than the account default" do
    assert PtcManager.AgentProfiles.model("codex") == "gpt-5.6-sol"
    assert PtcManager.AgentProfiles.model("claude") == "opus"
    assert PtcManager.AgentProfiles.model("cursor") == "cursor-grok-4.6-high"

    assert List.last(PtcManager.AgentProfiles.args("codex")) == "gpt-5.6-sol"
    assert "--model" in PtcManager.AgentProfiles.args("codex")
  end

  describe "outcome protocol v2 prompt" do
    setup do
      repository = repository_fixture(%{required_pre_pr_reviews: 2})
      issue = issue_fixture(repository, %{number: 42, title: "Fix the queue"})
      proposal_fixture(issue)
      {:ok, job} = Operations.approve_issue(issue.id, "andreas")

      job =
        job
        |> Job.changeset(%{
          branch_name: "ptc-manager/issue-42-job-#{job.id}",
          fencing_token: 3,
          stop_report_token: String.duplicate("t", 20)
        })
        |> Repo.update!()

      {:ok, repository: repository, issue: issue, job: job}
    end

    test "asks for both outcomes and names the v2 report path", ctx do
      job = protocol_v2_job(ctx.job, ctx.repository, "outcome_v2_prompt")

      prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(ctx.repository, ctx.issue, job)

      assert prompt =~ "ptc-outcome-"
      refute prompt =~ "ptc-stop-"
      assert prompt =~ ~s(report outcome "completed")
      assert prompt =~ ~s(report outcome "stopped")
      assert prompt =~ "accepted only when it names the commit actually on the branch"
    end

    test "still routes the retrospective to the channel the broker reads", ctx do
      job = protocol_v2_job(ctx.job, ctx.repository, "outcome_v2_prompt")

      prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(ctx.repository, ctx.issue, job)

      # Nothing reads jobs.result_completion yet, so removing these markers
      # would drop the retrospective from every published pull request.
      assert prompt =~ "PTC-AGENT-RETROSPECTIVE-BEGIN"
      assert prompt =~ "PTC-AGENT-RETROSPECTIVE-END"
      assert prompt =~ "The commit message is what reaches the pull request."
    end

    test "leaves the live v1 instruction exactly as it was", ctx do
      prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(ctx.repository, ctx.issue, ctx.job)

      assert prompt =~ "ptc-stop-"
      refute prompt =~ "ptc-outcome-"
      assert prompt =~ "If you cannot start:"

      assert prompt =~
               "Describe what is missing in plain language and name no secrets. Do not guess, do not work around it, and do not wait."

      refute prompt =~ ~s(report outcome "completed")
    end
  end

  test "builds repository-owned validation, provider-neutral review, and broker contract" do
    repository =
      repository_fixture(%{required_pre_pr_reviews: 2})

    issue = issue_fixture(repository, %{number: 42, title: "Fix the queue"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job =
      job
      |> Job.changeset(%{branch_name: "ptc-manager/issue-42-job-#{job.id}", fencing_token: 3})
      |> Repo.update!()

    prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(repository, issue, job)

    assert prompt =~ "Fix the issue completely"
    assert prompt =~ "Follow the repository instructions"
    assert prompt =~ "Maximum independent review rounds: 1"
    refute prompt =~ "Run this configured test command exactly"
    refute prompt =~ "codex-review"
    assert prompt =~ "PtcManager will publish it"
    assert prompt =~ "Do not push, create a pull request, or merge."
  end

  test "uses the review count frozen on the individual implementation job" do
    repository = repository_fixture(%{required_pre_pr_reviews: 2})
    easy_issue = issue_fixture(repository, %{number: 601})
    tricky_issue = issue_fixture(repository, %{number: 602})
    proposal_fixture(easy_issue)
    proposal_fixture(tricky_issue)

    assert {:ok, easy_job} = Operations.approve_issue(easy_issue.id, "andreas", 0)
    assert {:ok, tricky_job} = Operations.approve_issue(tricky_issue.id, "andreas", 3)

    easy_prompt =
      PtcManager.Dispatch.HerdrAdapter.build_prompt(repository, easy_issue, easy_job)

    tricky_prompt =
      PtcManager.Dispatch.HerdrAdapter.build_prompt(repository, tricky_issue, tricky_job)

    assert easy_prompt =~ "Maximum independent review rounds: 0"
    assert tricky_prompt =~ "Maximum independent review rounds: 3"
    refute tricky_prompt =~ "codex-review"
  end

  test "can assign fenced branch push and PR creation to the coding agent" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    repository = repository_fixture(%{required_pre_pr_reviews: 2})
    remote = remote_issue(1627) |> Map.put("title", "Correct MCP documentation")
    issue = issue_fixture(repository, IssueSnapshot.normalize!(remote, repository.id))
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    assert is_nil(job.publication_source)

    canonical = IssueSnapshot.normalize!(remote, repository.id)
    assert {:ok, job} = Operations.lease_job(job.id, "herdr:default", canonical, 60_000)
    assert job.publication_source == "agent"

    job =
      job
      |> Job.changeset(%{branch_name: "ptc-manager/issue-1627-job-#{job.id}"})
      |> Repo.update!()

    prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(repository, issue, job)

    assert prompt =~ "publish the reviewed commit in a pull request that closes the issue"
    assert prompt =~ "Branch: #{job.branch_name} → main"
    assert prompt =~ "Maximum independent review rounds: 1"
    assert prompt =~ "Read the issue, its comments, linked issues"
    assert prompt =~ "Push this branch and create a pull request. Do not merge."
    refute prompt =~ "fencing_token"
    refute prompt =~ "result="
  end

  defp approved_job_fixture(repository \\ repository_fixture(%{local_path: "/tmp/repository"})) do
    remote = remote_issue(System.unique_integer([:positive]))
    attrs = IssueSnapshot.normalize!(remote, repository.id)
    issue = issue_fixture(repository, attrs)
    proposal = proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    {repository, issue, proposal, job, remote}
  end

  defp refuse_dispatch!(change, reason, words) do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, Map.merge(remote, change)})

    assert {:error, ^reason} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)
    refute_receive {:dispatch_context, _context}
    rejected = Repo.get!(Job, job.id)
    assert rejected.state == "cancelled"
    assert rejected.last_error =~ words
  end

  defp remote_issue(number) do
    %{
      "number" => number,
      "title" => "Implement fenced dispatch",
      "html_url" => "https://github.com/example/repo/issues/#{number}",
      "body" => "Create one safe implementation attempt.",
      "state" => "open",
      "updated_at" => "2026-08-29T09:00:00Z",
      "parent" => nil,
      "sub_issues" => %{"nodes" => [], "total" => 0, "overflow" => false},
      "structure_projected" => true
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
