defmodule PtcManager.TestGitWorkspaceTest do
  use PtcManager.DataCase, async: false

  @moduletag :nightly

  alias PtcManager.Dispatch
  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Operations.{Job, PrPublication, WorktreeAllocation}
  alias PtcManager.Repo
  alias PtcManager.TestGitWorkspace
  alias PtcManager.TestScenario
  alias PtcManager.Worktrees

  defmodule ProductionAdapter do
    def dispatch(context) do
      HerdrAdapter.dispatch(context, command: Process.get(:test_git_workspace_command))
    end

    def remove_worktree(allocation) do
      HerdrAdapter.remove_worktree(allocation,
        command: Process.get(:test_git_workspace_command)
      )
    end
  end

  setup do
    workspace = TestGitWorkspace.configure_dispatch!("ptc-manager-git-workspace")
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    %{scenario: scenario, workspace: workspace}
  end

  test "real dispatch and cleanup paths reconcile lost worktree acknowledgements", %{
    scenario: scenario,
    workspace: workspace
  } do
    command_pid =
      start_supervised!({TestGitWorkspace.HerdrCommand, {workspace, scenario}})

    command = TestGitWorkspace.HerdrCommand.gateway(command_pid)
    Process.put(:test_git_workspace_command, command)

    TestScenario.approved_implementation!(scenario,
      number: 49,
      local_path: workspace.repository
    )

    :ok = TestScenario.operation_outcomes(scenario, :run_command, [:effect_then_error])

    assert {:ok, %{job: working}} =
             Dispatch.run_once(
               github: scenario,
               adapter: ProductionAdapter,
               worker_key: "herdr:scenario"
             )

    allocation = Repo.get_by!(WorktreeAllocation, job_id: working.id)
    assert File.dir?(allocation.path)
    assert working.state == "working"

    create_events = command_events(scenario, "add")
    assert length(create_events) == 1

    assert [%{id: workspace_id, path: worktree_path}] =
             TestGitWorkspace.HerdrCommand.workspaces(command)

    assert workspace_id == allocation.herdr_workspace
    assert worktree_path == allocation.path

    assert [["agent", "start", "impl_j" <> _ | start_options]] =
             TestGitWorkspace.HerdrCommand.agent_starts(command)

    assert Enum.take(start_options, 8) == [
             "--kind",
             "codex",
             "--pane",
             "#{workspace_id}:p1",
             "--timeout",
             "120000",
             "--",
             "--dangerously-bypass-approvals-and-sandbox"
           ]

    assert Enum.drop(start_options, 8) ==
             ["--model", PtcManager.AgentProfiles.model("codex")] ++
               PtcManager.CodexTrust.override_args([workspace.repository, allocation.path])

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    working
    |> Job.changeset(%{state: "done", ended_at: now})
    |> Repo.update!()

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: working.id,
      state: "published",
      idempotency_key: String.duplicate("a", 64),
      fencing_token: working.fencing_token,
      branch_name: working.branch_name,
      base_sha: workspace.source_sha,
      head_sha: workspace.source_sha,
      diff_digest: String.duplicate("b", 64),
      attempt_count: 1,
      pr_number: 49,
      pr_url: "https://github.com/example/repository/pull/49",
      remote_head_sha: workspace.source_sha,
      published_at: now,
      pr_state: "merged",
      pr_checked_at: now
    })
    |> Repo.insert!()

    allocation
    |> WorktreeAllocation.changeset(%{
      state: "terminal",
      head_sha: workspace.source_sha,
      last_used_at: now
    })
    |> Repo.update!()

    :ok = TestScenario.operation_outcomes(scenario, :run_command, [:effect_then_error])

    assert :ok = Worktrees.cleanup_terminal_once(ProductionAdapter)
    refute File.exists?(allocation.path)
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "removed"
    assert length(command_events(scenario, "remove")) == 1
    assert TestGitWorkspace.HerdrCommand.workspaces(command) == []
  end

  test "the Herdr contract fake rejects multiple open selectors", %{
    scenario: scenario,
    workspace: workspace
  } do
    command_pid = start_supervised!({TestGitWorkspace.HerdrCommand, {workspace, scenario}})
    command = TestGitWorkspace.HerdrCommand.gateway(command_pid)

    assert {:error, :invalid_test_herdr_open_selector} =
             TestGitWorkspace.HerdrCommand.run(
               command,
               [
                 "worktree",
                 "open",
                 "--cwd",
                 workspace.repository,
                 "--path",
                 Path.join(workspace.worktree_root, "missing"),
                 "--branch",
                 "main"
               ],
               1_000
             )
  end

  test "a read-only source Git directory ends dispatch safely with Git's explanation", %{
    scenario: scenario,
    workspace: workspace
  } do
    leased =
      TestScenario.leased_implementation!(scenario,
        number: 52,
        local_path: workspace.repository
      )

    # Mirrors a checkout the Herdr service sandbox mounts read-only: Git cannot
    # record the job branch, so no worktree exists afterwards. Root ignores
    # directory modes, so the failure can only be reproduced as another user.
    heads = Path.join(workspace.repository, ".git/refs/heads")
    File.chmod!(heads, 0o555)
    on_exit(fn -> File.chmod!(heads, 0o755) end)

    command = TestGitWorkspace.with_runner(workspace, scenario)

    result =
      HerdrAdapter.dispatch(
        %{
          job: leased,
          issue: leased.issue,
          repository: leased.repository,
          source: %{sha: workspace.source_sha, ref: "refs/remotes/origin/main"}
        },
        command: command
      )

    if File.stat!(heads).access == :read do
      assert {:error, {:safe, {:worktree_create_failed, message}}} = result
      assert message =~ "cannot lock ref"
      assert message =~ leased.branch_name
    end

    refute File.exists?(leased.worktree_allocation.path)
  end

  test "production adoption rejects a clean standalone clone at the reserved path", %{
    scenario: scenario,
    workspace: workspace
  } do
    leased =
      TestScenario.leased_implementation!(scenario,
        number: 51,
        local_path: workspace.repository
      )

    :ok =
      TestGitWorkspace.standalone_clone_at!(
        workspace,
        leased.worktree_allocation.path,
        leased.branch_name
      )

    command = TestGitWorkspace.with_runner(workspace, scenario)

    assert {:error,
            {:uncertain,
             {:worktree_create_unconfirmed, _create_error, :worktree_create_identity_mismatch}}} =
             HerdrAdapter.dispatch(
               %{
                 job: leased,
                 issue: leased.issue,
                 repository: leased.repository,
                 source: %{sha: workspace.source_sha, ref: "refs/remotes/origin/main"}
               },
               command: command
             )

    assert File.dir?(leased.worktree_allocation.path)
  end

  test "adopts one real worktree after creation succeeds but acknowledgement is lost", %{
    scenario: scenario,
    workspace: workspace
  } do
    worktree = TestGitWorkspace.worktree(workspace, "issue-42")
    :ok = TestScenario.operation_outcomes(scenario, :run_command, [:effect_then_error, :ok])

    assert {:error, {:uncertain, :scenario_command_ack_lost}} =
             TestGitWorkspace.create(workspace, scenario, worktree)

    assert File.dir?(worktree.path)

    assert {:ok, {:adopted, ^worktree}} =
             TestGitWorkspace.ensure(workspace, scenario, worktree)

    create_events =
      Enum.filter(TestScenario.trace(scenario), fn event ->
        event.operation == :run_command and "add" in event.target.args
      end)

    assert length(create_events) == 1
  end

  test "cleanup acknowledgement loss reconciles to one removed worktree", %{
    scenario: scenario,
    workspace: workspace
  } do
    worktree = TestGitWorkspace.worktree(workspace, "issue-43")
    assert {:ok, _output} = TestGitWorkspace.create(workspace, scenario, worktree)

    :ok =
      TestScenario.operation_outcomes(
        scenario,
        :run_command,
        [:ok, :ok, :effect_then_error, :ok]
      )

    assert {:error, {:uncertain, :scenario_command_ack_lost}} =
             TestGitWorkspace.cleanup(workspace, scenario, worktree)

    refute File.exists?(worktree.path)

    assert {:ok, :already_removed} =
             TestGitWorkspace.cleanup(workspace, scenario, worktree)

    remove_events =
      Enum.filter(TestScenario.trace(scenario), fn event ->
        event.operation == :run_command and "remove" in event.target.args
      end)

    assert length(remove_events) == 1
  end

  test "cleanup refuses a forged path before executing Git", %{
    scenario: scenario,
    workspace: workspace
  } do
    worktree = TestGitWorkspace.worktree(workspace, "issue-44")
    forged = %{worktree | path: Path.join(workspace.root, "unowned")}

    assert {:error, :unsafe_worktree_identity} =
             TestGitWorkspace.cleanup(workspace, scenario, forged)

    assert TestScenario.trace(scenario) == []
  end

  test "cleanup refuses a symlink even when the retained fields are otherwise exact", %{
    scenario: scenario,
    workspace: workspace
  } do
    worktree = TestGitWorkspace.worktree(workspace, "issue-45")
    File.ln_s!(workspace.repository, worktree.path)

    assert {:error, :unsafe_worktree_symlink} =
             TestGitWorkspace.cleanup(workspace, scenario, worktree)

    assert TestScenario.trace(scenario) == []
    assert File.read_link!(worktree.path) == workspace.repository
  end

  test "does not adopt a prunable registry entry whose checkout disappeared", %{
    scenario: scenario,
    workspace: workspace
  } do
    worktree = TestGitWorkspace.worktree(workspace, "issue-46")
    assert {:ok, _output} = TestGitWorkspace.create(workspace, scenario, worktree)
    File.rm_rf!(worktree.path)

    assert {:error, :stale_worktree_registry_entry} =
             TestGitWorkspace.reconcile(workspace, scenario, worktree)
  end

  test "does not adopt a registered path replaced by a symlink", %{
    scenario: scenario,
    workspace: workspace
  } do
    worktree = TestGitWorkspace.worktree(workspace, "issue-50")
    moved = worktree.path <> "-moved"
    assert {:ok, _output} = TestGitWorkspace.create(workspace, scenario, worktree)
    File.rename!(worktree.path, moved)
    File.ln_s!(moved, worktree.path)

    assert {:error, :unsafe_worktree_administrative_link} =
             TestGitWorkspace.reconcile(workspace, scenario, worktree)
  end

  test "a later singular outcome replaces an unfinished sequence", %{
    scenario: scenario,
    workspace: workspace
  } do
    first = TestGitWorkspace.worktree(workspace, "issue-47")
    second = TestGitWorkspace.worktree(workspace, "issue-48")

    :ok = TestScenario.operation_outcomes(scenario, :run_command, [:fail_before, :fail_before])
    :ok = TestScenario.operation_outcome(scenario, :run_command, :ok)

    assert {:ok, _output} = TestGitWorkspace.create(workspace, scenario, first)

    :ok = TestScenario.operation_outcome(scenario, :run_command, :fail_before)
    :ok = TestScenario.operation_outcomes(scenario, :run_command, [:ok])

    assert {:ok, _output} = TestGitWorkspace.create(workspace, scenario, second)
  end

  defp command_events(scenario, git_subcommand) do
    Enum.filter(TestScenario.trace(scenario), fn event ->
      event.operation == :run_command and git_subcommand in event.target.args
    end)
  end
end
