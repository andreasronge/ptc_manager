defmodule PtcManager.AutomationsTest do
  use PtcManager.DataCase, async: false

  import PtcManager.OperationsFixtures

  alias PtcManager.Automations
  alias PtcManager.Automations.{DefinitionVersion, Invocation, Trigger}
  alias PtcManager.MaintainerActions
  alias PtcManager.Repo

  defmodule GitTrustCommand do
    def git_command(args) do
      send(self(), {:workspace_event, {:git, args}})
      {"", 0}
    end
  end

  defmodule RejectedOpenCommand do
    def run(["worktree", "open" | _args]) do
      send(self(), {:workspace_event, :rejected_open})
      {:error, :open_failed}
    end
  end

  # Every managed pane now asks whether the kind it is about to start is still
  # signed in. The real wrapper is only on the worker machine.
  defmodule AgentLoginCommand do
    def login_command(_args), do: {"", 0}
  end

  defmodule ClaudeTrustCommand do
    def trust_command(args) do
      send(
        Application.fetch_env!(:ptc_manager, :worker_claude_trust_test_pid),
        {:claude_trust, args}
      )

      {"", 0}
    end
  end

  defmodule GenericHerdrCommand do
    def run(args, _timeout \\ nil) do
      cond do
        Enum.take(args, 2) == ["worktree", "open"] ->
          send(self(), {:workspace_event, :open})
          workspace_path = Enum.at(args, Enum.find_index(args, &(&1 == "--cwd")) + 1)
          Process.put({__MODULE__, :workspace_path}, workspace_path)

          {:ok,
           Jason.encode!(%{
             "result" => %{
               "workspace" => %{"workspace_id" => "generic-workspace"},
               "root_pane" => %{"pane_id" => "generic-pane"}
             }
           })}

        Enum.take(args, 2) == ["agent", "start"] ->
          workspace_path = Process.get({__MODULE__, :workspace_path})
          false = Enum.any?(args, &String.contains?(&1, "{{workspace_path"))
          true = workspace_path in args
          true = ~s("#{workspace_path}") in args

          {:ok,
           Jason.encode!(%{
             "result" => %{"agent" => %{"agent_session" => %{"value" => "generic-session"}}}
           })}

        Enum.take(args, 2) == ["agent", "prompt"] ->
          true = option_values(args, "--until") == ["working", "blocked"]
          prompt = Enum.at(args, 3)
          prepare_prompt_result(prompt)

          if String.starts_with?(prompt, "Read and follow the complete task") do
            {:error,
             {:herdr_exit, 1,
              ~s({"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed state change within 5000 ms; status is idle and state_change_seq remained 40"},"id":"cli:agent:prompt"})}}
          else
            {:ok, ~s({"result":{"state":"working"}})}
          end

        Enum.take(args, 2) == ["agent", "get"] ->
          {:ok, ~s({"result":{"agent":{"agent_status":"working","state_change_seq":41}}})}

        Enum.take(args, 2) == ["agent", "wait"] ->
          true = option_values(args, "--until") == ["idle", "done", "blocked"]
          complete_prompt_result()
          {:ok, ~s({"result":{"state":"idle"}})}

        Enum.take(args, 2) == ["workspace", "close"] ->
          {:ok, "{}"}

        true ->
          {:error, {:unexpected_command, args}}
      end
    end

    defp result do
      %{
        "outcome" => "no-changes",
        "private_summary" => "No repository change was needed.",
        "why_it_matters" => "The configured check completed.",
        "scope" => "small",
        "risk" => "low",
        "technical_evidence" => "The invented test agent inspected the fixture.",
        "github_changes" => [],
        "evidence" => ["contract-test"],
        "decision_question" => "",
        "decision_options" => [],
        "created_issue_numbers" => [],
        "suggestions" => []
      }
    end

    defp assert_schema!(path) do
      body = File.read!(path)
      true = body =~ ~s("private_summary")
      :ok
    end

    defp option_values(args, option) do
      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        [^option, value] -> [value]
        _pair -> []
      end)
    end

    defp prepare_prompt_result("Initialization check only." <> _rest = prompt) do
      attempt = Process.get({__MODULE__, :ready_attempt}, 0) + 1
      Process.put({__MODULE__, :ready_attempt}, attempt)

      if attempt == 1 do
        Process.put({__MODULE__, :pending_prompt_result}, :swallowed)
      else
        [token] = Regex.run(~r/exactly (ready-\d+-\d+)/, prompt, capture: :all_but_first)
        [path] = Regex.run(~r/rename it to (\/\S+?\.ready)\./, prompt, capture: :all_but_first)
        Process.put({__MODULE__, :pending_prompt_result}, {:ready, path, token})
      end
    end

    defp prepare_prompt_result(loader) do
      [prompt_path] = Regex.run(~r/task at (.+?\.txt)\./, loader, capture: :all_but_first)
      prompt = File.read!(prompt_path)
      [path] = Regex.run(~r/to (\/\S+?\.json)\b/, prompt, capture: :all_but_first)
      [schema] = Regex.run(~r/read (\/\S+?\.schema\.json)\b/, prompt, capture: :all_but_first)
      assert_schema!(schema)
      true = byte_size(loader) < 500
      true = prompt =~ String.duplicate("Long context line.\n", 100)
      Process.put({__MODULE__, :pending_prompt_result}, {:result, path})
    end

    defp complete_prompt_result do
      case Process.delete({__MODULE__, :pending_prompt_result}) do
        :swallowed ->
          :ok

        {:ready, path, token} ->
          File.write!(path, token <> "\n")

        {:result, path} ->
          false = File.exists?(path)
          temporary_path = path <> ".tmp"
          File.write!(temporary_path, Jason.encode!(result()))
          File.rename!(temporary_path, path)
      end
    end
  end

  defmodule InvestigationWorkspaceSetup do
    def run(path, action) do
      send(Process.get(:investigation_test_pid), {:investigation_setup, path, action.id})
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      report = %{
        state: "passed",
        script: "scripts/ptc/bootstrap",
        source_sha: action.target_snapshot["source_sha"],
        started_at: now,
        ended_at: now,
        duration_ms: 1,
        exit_status: 0,
        output: "ready\n",
        output_truncated: false,
        cache_state: "hit",
        phase_durations: %{},
        error: nil
      }

      Process.get(:investigation_setup_result) || {:ok, report}
    end
  end

  defmodule InvestigationHerdrCommand do
    def run(args, _timeout \\ nil) do
      send(Process.get(:investigation_test_pid), {:investigation_command, args})

      cond do
        Enum.take(args, 2) == ["worktree", "create"] ->
          path = args |> Enum.drop_while(&(&1 != "--path")) |> Enum.at(1)
          File.mkdir_p!(path)

          if Process.get(:investigation_attach_failure) do
            PtcManager.Repo.update_all(
              PtcManager.Operations.AgentRun,
              set: [state: "done"]
            )
          end

          {:ok,
           Jason.encode!(%{
             "result" => %{
               "workspace" => %{"workspace_id" => "investigation-workspace"},
               "root_pane" => %{"pane_id" => "investigation-pane"}
             }
           })}

        Enum.take(args, 2) == ["agent", "start"] ->
          {:ok,
           Jason.encode!(%{
             "result" => %{"agent" => %{"agent_session" => %{"value" => "review-session"}}}
           })}

        Enum.take(args, 2) == ["agent", "prompt"] ->
          complete_prompt(args)
          {:ok, ~s({"result":{"state":"working"}})}

        Enum.take(args, 2) == ["agent", "wait"] ->
          {:ok, ~s({"result":{"state":"idle"}})}

        Enum.take(args, 2) == ["worktree", "remove"] ->
          Process.get(:investigation_remove_result) || {:ok, "{}"}

        true ->
          {:error, {:unexpected_command, args}}
      end
    end

    defp complete_prompt(args) do
      prompt = Enum.at(args, 3)

      if String.starts_with?(prompt, "Initialization check only.") do
        [token] = Regex.run(~r/exactly (ready-\d+-\d+)/, prompt, capture: :all_but_first)
        [path] = Regex.run(~r/rename it to (\/\S+?\.ready)\./, prompt, capture: :all_but_first)
        File.write!(path, token <> "\n")
      else
        [prompt_path] = Regex.run(~r/task at (.+?\.txt)\./, prompt, capture: :all_but_first)
        task = File.read!(prompt_path)
        [path] = Regex.run(~r/to (\/\S+?\.json)\b/, task, capture: :all_but_first)

        result = %{
          "outcome" => "ready",
          "private_summary" => "The regression was reproduced.",
          "why_it_matters" => "The issue is ready to implement.",
          "scope" => "small",
          "risk" => "medium",
          "technical_evidence" => "A focused test reproduced the failure.",
          "github_changes" => ["Updated the issue evidence."],
          "evidence" => ["mix test test/example_test.exs"],
          "decision_question" => "",
          "decision_options" => [],
          "created_issue_numbers" => [],
          "suggestions" => []
        }

        File.write!(path, Jason.encode!(result))
      end
    end
  end

  defmodule InvestigationCleanupAdapter do
    def open_action_workspace(repository_path, path, label) do
      send(
        Process.get(:investigation_test_pid),
        {:investigation_recover, repository_path, path, label}
      )

      {:ok, "recovered-investigation-workspace"}
    end

    def remove_action_workspace(workspace) do
      send(Process.get(:investigation_test_pid), {:investigation_cleanup, workspace})
      :ok
    end
  end

  defmodule MissingInvestigationCleanupAdapter do
    def remove_action_workspace(workspace) do
      send(Process.get(:investigation_test_pid), {:investigation_cleanup_missing, workspace})

      PtcManager.Dispatch.HerdrAdapter.action_workspace_removal_result(
        {:error,
         {:herdr_exit, 1, Jason.encode!(%{"error" => %{"code" => "workspace_not_found"}})}}
      )
    end
  end

  defmodule UncertainInvestigationCleanupAdapter do
    def remove_action_workspace(workspace) do
      send(Process.get(:investigation_test_pid), {:investigation_cleanup_uncertain, workspace})
      {:error, :herdr_unavailable}
    end
  end

  defmodule InvestigationCleanupGit do
    def run(args) do
      send(Process.get(:investigation_test_pid), {:investigation_cleanup_git, args})

      case Process.get(:investigation_cleanup_git_results, []) do
        [result | remaining] ->
          Process.put(:investigation_cleanup_git_results, remaining)
          result

        [] ->
          {"", 0}
      end
    end
  end

  defmodule ChangedBranchCleanupGit do
    def run(args) do
      send(Process.get(:investigation_test_pid), {:changed_branch_cleanup_git, args})

      case args do
        ["-C", _, "update-ref", "-d", "refs/heads/" <> _branch] -> {"", 0}
        ["-C", _, "update-ref", "-d", "refs/heads/" <> _branch, _old_sha] -> {"changed", 1}
        _args -> {"", 0}
      end
    end
  end

  test "new repositories receive versioned built-in definitions idempotently" do
    repository = repository_fixture()

    definitions = Automations.list_definitions(repository)
    assert length(definitions) == 12
    assert Enum.all?(definitions, &match?(%DefinitionVersion{version: 1}, &1.current_version))

    assert Enum.all?(definitions, fn definition ->
             definition.current_version.prompt =~
               "#{repository.github_owner}/#{repository.github_name}"
           end)

    assert :ok = Automations.ensure_defaults(repository)
    assert length(Automations.list_definitions(repository)) == 12

    review = Automations.get_definition(repository, "review_issue")
    assert review.current_version.execution_profile == "ephemeral_investigation"
    assert review.current_version.resource_class == "heavy"
    assert review.current_version.prompt =~ "run relevant tests"
  end

  test "review issue prepares and removes a writable disposable investigation worktree" do
    %{action: action, issue: issue, root: root, source_sha: source_sha} =
      claimed_investigation_fixture!()

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    assert_receive {:investigation_command,
                    [
                      "worktree",
                      "create",
                      "--cwd",
                      _,
                      "--branch",
                      branch,
                      "--base",
                      ^source_sha,
                      "--path",
                      path | _rest
                    ]}

    assert branch =~ "review-issue-#{issue.id}-action-#{action.id}"
    assert String.starts_with?(path, root <> "/")
    assert_receive {:investigation_setup, ^path, action_id}
    assert action_id == action.id
    assert_receive {:investigation_command, ["agent", "start" | start_args]}
    assert path in start_args

    assert_receive {:investigation_command,
                    ["worktree", "remove", "--workspace", "investigation-workspace", "--force"]}

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    assert run.workspace_setup_state == "passed"
    assert run.workspace_setup_script == "scripts/ptc/bootstrap"
    assert run.workspace_setup_duration_ms == 1
    assert run.workspace_setup_exit_status == 0
    assert run.workspace_setup_output == "ready\n"
    assert run.workspace_setup_cache_state == "hit"
  end

  test "Codex investigations trust both the parent checkout and disposable worktree" do
    %{action: action} = claimed_investigation_fixture!()

    Application.put_env(:ptc_manager, :agent_profiles, %{
      "codex" => %{
        "enabled" => true,
        "args" => ["-c", ~s(projects={{{workspace_path_toml}}={trust_level="trusted"}})]
      }
    })

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    assert_receive {:investigation_command, ["agent", "start" | args]}
    override = Enum.find(args, &String.starts_with?(&1, "projects="))
    assert override =~ PtcManager.CodexTrust.toml_basic_string(action.repository.local_path)
    assert_receive {:investigation_command, ["worktree", "create" | create_args]}
    path = create_args |> Enum.drop_while(&(&1 != "--path")) |> Enum.at(1)
    assert override =~ PtcManager.CodexTrust.toml_basic_string(path)
  end

  test "worktree reconciliation retries investigation cleanup while actions are disabled and draining" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    previous_enabled = Application.get_env(:ptc_manager, :agent_actions_enabled)
    previous_mode = Application.get_env(:ptc_manager, :operational_mode)
    previous_adapter = Application.get_env(:ptc_manager, :investigation_workspace_adapter)
    Application.put_env(:ptc_manager, :agent_actions_enabled, false)
    Application.put_env(:ptc_manager, :operational_mode, :draining)

    Application.put_env(
      :ptc_manager,
      :investigation_workspace_adapter,
      InvestigationCleanupAdapter
    )

    on_exit(fn ->
      restore_env(:agent_actions_enabled, previous_enabled)
      restore_env(:operational_mode, previous_mode)
      restore_env(:investigation_workspace_adapter, previous_adapter)
    end)

    PtcManager.Worktrees.cleanup_once()

    assert_receive {:investigation_cleanup, "investigation-workspace"}
    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    assert run.disposable_cleanup_state == nil
  end

  test "late cleanup belongs to its own attempt, not the newest run" do
    %{action: action, old_run: old_run, new_run: new_run} = retried_investigation_fixture!()

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup(
               action,
               &InvestigationCleanupAdapter.remove_action_workspace/1,
               InvestigationCleanupGit
             )

    assert cleaned.id == old_run.id
    assert_receive {:investigation_cleanup, "old-workspace"}

    assert {:ok, :empty} =
             PtcManager.InvestigationWorkspaces.cleanup(
               action,
               &InvestigationCleanupAdapter.remove_action_workspace/1,
               InvestigationCleanupGit
             )

    refute_receive {:investigation_cleanup, "new-workspace"}

    assert Repo.get!(PtcManager.Operations.AgentRun, new_run.id).disposable_cleanup_state ==
             "workspace_open"
  end

  test "terminal cleanup derives old workspace identity from the run's fencing token" do
    %{action: action, old_run: old_run} = retried_investigation_fixture!()

    action
    |> PtcManager.Operations.AgentAction.changeset(%{state: "done", target_snapshot: %{}})
    |> Repo.update!()

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               InvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    assert cleaned.id == old_run.id
    assert_receive {:investigation_cleanup, "old-workspace"}
  end

  test "failed investigation setup retains its bounded diagnostics" do
    %{action: action} = claimed_investigation_fixture!()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    sha256 = String.duplicate("c", 64)

    Process.put(
      :investigation_setup_result,
      {:error,
       %{
         state: "failed",
         script: "scripts/ptc/bootstrap",
         source_sha: sha256,
         started_at: now,
         ended_at: DateTime.add(now, 2, :second),
         duration_ms: 2_000,
         exit_status: 17,
         output: "dependency installation failed\n",
         output_truncated: false,
         cache_state: "miss",
         phase_durations: %{"dependencies_ms" => 1_900},
         error: :workspace_setup_failed
       }}
    )

    assert {:error, {:investigation_workspace_setup_failed, :workspace_setup_failed}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    assert run.workspace_setup_state == "failed"
    assert run.workspace_setup_source_sha == sha256
    assert run.workspace_setup_duration_ms == 2_000
    assert run.workspace_setup_exit_status == 17
    assert run.workspace_setup_output == "dependency installation failed\n"
    assert run.workspace_setup_cache_state == "miss"
    assert run.workspace_setup_phase_durations == %{"dependencies_ms" => 1_900}
    assert run.workspace_setup_error == ":workspace_setup_failed"
    refute_receive {:investigation_command, ["agent", "start" | _args]}
  end

  test "failed investigation cleanup is persisted and retried after the action ends" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    assert run.herdr_workspace == "investigation-workspace"
    assert Map.fetch!(run, :disposable_cleanup_state) == "workspace_open"
    assert is_binary(Map.fetch!(run, :disposable_worktree_path))
    assert is_binary(Map.fetch!(run, :disposable_worktree_branch))

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               InvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    assert cleaned.id == run.id
    assert cleaned.herdr_workspace == nil
    assert Map.fetch!(cleaned, :disposable_cleanup_state) == nil
    assert Map.fetch!(cleaned, :disposable_worktree_path) == nil
    assert Map.fetch!(cleaned, :disposable_worktree_branch) == nil
    assert_receive {:investigation_cleanup, "investigation-workspace"}

    assert_receive {:investigation_cleanup_git,
                    [
                      "-C",
                      _,
                      "update-ref",
                      "-d",
                      "refs/heads/" <> _branch
                    ]}
  end

  test "an attach failure removes the decoded Herdr workspace" do
    %{action: action} = claimed_investigation_fixture!()
    Process.put(:investigation_attach_failure, true)

    assert {:error, :agent_action_run_missing} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    assert_receive {:investigation_command,
                    ["worktree", "remove", "--workspace", "investigation-workspace", "--force"]}
  end

  test "terminal cleanup recovers a Herdr workspace after a crash before its id was persisted" do
    %{action: action, root: root, token: token} = claimed_investigation_fixture!()
    {:ok, identity} = PtcManager.Repository.InvestigationWorkspace.identity(action)
    path = PtcManager.Repository.InvestigationWorkspace.path(root, action.repository, action)

    assert {:ok, _run} =
             PtcManager.Operations.prepare_agent_action_disposable_workspace(
               action.id,
               action.attempt_count,
               path,
               identity.branch
             )

    File.mkdir_p!(path)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(action.id, token, {:error, :killed})

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               InvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    assert cleaned.disposable_cleanup_state == nil
    expected_label = "review-issue-#{action.target_id}"

    assert_receive {:investigation_recover, repository_path, ^path, ^expected_label}

    assert repository_path == Path.expand(System.tmp_dir!())
    assert_receive {:investigation_cleanup, "recovered-investigation-workspace"}
  end

  test "investigation cleanup is leased and treats already-removed resources as success" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    File.rm_rf!(run.disposable_worktree_path)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    assert {:ok, _claimed, cleanup_token} =
             PtcManager.Operations.claim_disposable_workspace_cleanup(run.id)

    assert {:ok, :empty} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               MissingInvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    refute_receive {:investigation_cleanup_missing, _workspace}

    assert {:ok, _released} =
             PtcManager.Operations.fail_disposable_workspace_cleanup(run.id, cleanup_token)

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               MissingInvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    assert cleaned.disposable_cleanup_state == nil
    assert_receive {:investigation_cleanup_missing, "investigation-workspace"}
  end

  test "investigation cleanup retains workspace identity after an uncertain removal failure" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    File.rm_rf!(run.disposable_worktree_path)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    assert {:error, {:investigation_workspace_cleanup_failed, :herdr_unavailable}} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               UncertainInvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    retained = Repo.get!(PtcManager.Operations.AgentRun, run.id)
    assert retained.herdr_workspace == "investigation-workspace"
    assert retained.disposable_cleanup_state == "workspace_open"
    assert retained.disposable_cleanup_token == nil
    assert_receive {:investigation_cleanup_uncertain, "investigation-workspace"}
  end

  test "workspace-not-found cleanup removes a worktree that still exists on disk" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    assert File.dir?(run.disposable_worktree_path)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               MissingInvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    assert cleaned.disposable_cleanup_state == nil
    assert_receive {:investigation_cleanup_missing, "investigation-workspace"}

    assert_receive {:investigation_cleanup_git,
                    ["-C", _, "worktree", "remove", "--force", "--", worktree_path]}

    assert worktree_path == run.disposable_worktree_path
  end

  test "investigation cleanup retries an already-deleted branch idempotently" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)

    assert {:ok, _claimed, cleanup_token} =
             PtcManager.Operations.claim_disposable_workspace_cleanup(run.id)

    assert {:ok, branch_pending} =
             PtcManager.Operations.advance_disposable_workspace_cleanup(
               run.id,
               cleanup_token,
               "workspace_open",
               "branch_pending"
             )

    assert branch_pending.disposable_cleanup_state == "branch_pending"

    assert {:ok, _released} =
             PtcManager.Operations.fail_disposable_workspace_cleanup(run.id, cleanup_token)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    Process.put(:investigation_cleanup_git_results, [{"missing", 1}, {"", 1}])

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               InvestigationCleanupAdapter,
               InvestigationCleanupGit
             )

    assert cleaned.disposable_cleanup_state == nil

    assert_receive {:investigation_cleanup_git, ["-C", _, "update-ref", "-d", "refs/heads/" <> _]}

    assert_receive {:investigation_cleanup_git,
                    ["-C", _, "show-ref", "--verify", "--quiet", "refs/heads/" <> _]}
  end

  test "investigation cleanup deletes its unique branch even when the agent committed" do
    %{action: action, token: token} = claimed_investigation_fixture!()
    Process.put(:investigation_remove_result, {:error, :herdr_unavailable})

    assert {:ok, %{"outcome" => "ready"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(
               action.id,
               token,
               {:ok, %{"outcome" => "ready"}}
             )

    assert {:ok, cleaned} =
             PtcManager.InvestigationWorkspaces.cleanup_terminal_once(
               InvestigationCleanupAdapter,
               ChangedBranchCleanupGit
             )

    assert cleaned.disposable_cleanup_state == nil

    assert_receive {:changed_branch_cleanup_git,
                    ["-C", _, "update-ref", "-d", "refs/heads/" <> _branch]}
  end

  test "repository removal waits for disposable cleanup metadata to clear" do
    %{action: action, root: root, token: token} = claimed_investigation_fixture!()
    {:ok, identity} = PtcManager.Repository.InvestigationWorkspace.identity(action)
    path = PtcManager.Repository.InvestigationWorkspace.path(root, action.repository, action)

    assert {:ok, _run} =
             PtcManager.Operations.prepare_agent_action_disposable_workspace(
               action.id,
               action.attempt_count,
               path,
               identity.branch
             )

    assert {:ok, _completed} =
             PtcManager.Operations.complete_agent_action(action.id, token, {:error, :stopped})

    assert {:error, :active_work} = PtcManager.Operations.remove_repository(action.repository_id)
  end

  test "heavy issue reviews and legacy repairs share implementation capacity" do
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    previous_capacity = Application.get_env(:ptc_manager, :heavy_agent_capacity)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :heavy_agent_capacity, 1)

    on_exit(fn ->
      restore_env(:dispatch_enabled, previous_dispatch)
      restore_env(:heavy_agent_capacity, previous_capacity)
    end)

    repository = repository_fixture()
    implementation_issue = issue_fixture(repository, %{number: 9_101})
    proposal_fixture(implementation_issue)
    {:ok, job} = PtcManager.Operations.approve_issue(implementation_issue.id, "maintainer")

    worker_fixture(%{
      worker_key: "herdr:default",
      capabilities: %{"herdr" => true, "implementation_slots" => 1}
    })

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    legacy_repair =
      %PtcManager.Operations.AgentAction{}
      |> PtcManager.Operations.AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_pr",
        target_type: "pull_request",
        target_id: 9_100,
        target_label: "legacy repair",
        prompt_version: 1,
        prompt: "Repair the pull request",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "done",
        attempt_count: 1,
        requested_at: now,
        started_at: now,
        ended_at: now
      })
      |> Repo.insert!()

    worker = Repo.get_by!(PtcManager.Operations.Worker, worker_key: "herdr:default")

    assert {:ok, legacy_run} =
             PtcManager.Operations.create_agent_run(%{
               worker_id: worker.id,
               agent_action_id: legacy_repair.id,
               role: "implementer",
               state: "working",
               agent_name: "legacy_repair",
               started_at: now,
               last_heartbeat_at: now
             })

    remote = %{
      state: "open",
      content_digest: implementation_issue.content_digest,
      github_updated_at: implementation_issue.github_updated_at,
      blocking_issues: [],
      dependency_overflow: false
    }

    assert {:error, :dispatch_capacity} =
             PtcManager.Operations.lease_job(job.id, "herdr:default", remote, 60_000)

    legacy_run
    |> PtcManager.Operations.AgentRun.changeset(%{state: "done", ended_at: now})
    |> Repo.update!()

    assert {:ok, _leased} =
             PtcManager.Operations.lease_job(job.id, "herdr:default", remote, 60_000)

    review_issue = issue_fixture(repository, %{number: 9_102})

    assert {:ok, review} =
             MaintainerActions.enqueue("review_issue", review_issue.id, "maintainer")

    assert {:error, :dispatch_capacity} = PtcManager.Operations.claim_agent_action(review.id)
  end

  test "queued repair work has priority over a heavy issue review" do
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    on_exit(fn -> restore_env(:dispatch_enabled, previous_dispatch) end)

    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 9_111})
    assert {:ok, review} = MaintainerActions.enqueue("review_issue", issue.id, "maintainer")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %PtcManager.Operations.AgentAction{}
    |> PtcManager.Operations.AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "repair_pr",
      target_type: "pull_request",
      target_id: 9_112,
      target_label: "priority repair",
      prompt_version: 1,
      prompt: "Repair the pull request",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "maintainer",
      state: "queued",
      attempt_count: 0,
      requested_at: now
    })
    |> Repo.insert!()

    worker_fixture(%{
      worker_key: "herdr:default",
      capabilities: %{"herdr" => true, "implementation_slots" => 1}
    })

    assert {:error, :delivery_priority} = PtcManager.Operations.claim_agent_action(review.id)
  end

  test "editing an action creates an immutable version used only by future actions" do
    repository = repository_fixture()
    issue = issue_fixture(repository)

    assert {:ok, first} = MaintainerActions.enqueue("prepare_issue", issue.id, "maintainer")
    definition = Automations.get_definition(repository, "prepare_issue")
    first_version = definition.current_version

    attrs =
      first_version
      |> Map.from_struct()
      |> Map.take([
        :target_type,
        :execution_profile,
        :agent_selector,
        :github_access,
        :queue_lane,
        :resource_class,
        :lock_policy,
        :timeout_seconds,
        :result_type,
        :result_protocol_version,
        :prompt,
        :configuration_snapshot
      ])
      |> Map.put(:prompt, "Use a shorter maintainer explanation for future runs.")

    assert {:ok, second_version} = Automations.create_version(definition, attrs, "maintainer")
    assert second_version.version == 2
    assert Repo.get!(DefinitionVersion, first_version.id).prompt == first_version.prompt

    first = Repo.get!(PtcManager.Operations.AgentAction, first.id)
    assert first.automation_definition_version_id == first_version.id

    first
    |> PtcManager.Operations.AgentAction.changeset(%{state: "done", ended_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:ok, second} = MaintainerActions.enqueue("prepare_issue", issue.id, "maintainer")
    assert second.automation_definition_version_id == second_version.id
    assert second.prompt =~ "Use a shorter maintainer explanation for future runs."
    refute first.prompt =~ "Use a shorter maintainer explanation for future runs."
  end

  test "the built-in implementation prompt asks for the follow-up label" do
    repository = repository_fixture()
    definition = Automations.get_definition(repository, "implement_issue")

    assert definition.current_version.created_by == "system:built-in"

    assert definition.current_version.prompt =~
             "add the label `ptc:follow-up` to the pull request"
  end

  test "implementation approval freezes its user-owned prompt" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)

    definition = Automations.get_definition(repository, "implement_issue")
    current = definition.current_version

    attrs =
      current
      |> version_attrs()
      |> Map.put(
        :prompt,
        "Use this repository's normal pull-request policy. Keep the implementation change tightly scoped."
      )

    assert {:ok, configured} = Automations.create_version(definition, attrs, "maintainer")

    assert {:ok, job} = PtcManager.Operations.approve_issue(issue.id, "maintainer")
    assert job.automation_definition_version_id == configured.id
    assert job.prompt_instructions =~ "Use this repository's normal pull-request policy."
    assert job.prompt_instructions =~ "Keep the implementation change tightly scoped."

    later_attrs = Map.put(attrs, :prompt, "This later edit must not alter approved work.")
    assert {:ok, _later} = Automations.create_version(definition, later_attrs, "maintainer")

    frozen = Repo.get!(PtcManager.Operations.Job, job.id).prompt_instructions
    assert frozen =~ "Keep the implementation change tightly scoped."
    refute frozen =~ "This later edit must not alter approved work."
  end

  defp version_attrs(version) do
    version
    |> Map.from_struct()
    |> Map.take([
      :target_type,
      :execution_profile,
      :agent_selector,
      :github_access,
      :queue_lane,
      :resource_class,
      :lock_policy,
      :timeout_seconds,
      :result_type,
      :result_protocol_version,
      :prompt,
      :configuration_snapshot
    ])
  end

  test "repository defaults include disabled schedules where updates are not relevant" do
    runner = repository_fixture(%{github_name: "ptc_runner"})
    manager = repository_fixture(%{github_name: "ptc_manager"})

    runner_digest = Automations.get_definition(runner, "daily_digest")
    manager_digest = Automations.get_definition(manager, "daily_digest")

    assert Enum.any?(runner_digest.triggers, &(&1.trigger_type == "schedule" and &1.enabled))
    refute Enum.any?(manager_digest.triggers, &(&1.trigger_type == "schedule" and &1.enabled))
    assert Enum.any?(runner_digest.triggers, &(&1.trigger_type == "manual" and &1.enabled))
    refute Enum.any?(manager_digest.triggers, &(&1.trigger_type == "manual" and &1.enabled))
  end

  test "a definition may hold several schedules and the bootstrap recognises the built-in one by its marker" do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "daily_digest")
    built_in = Enum.find(definition.triggers, &(&1.trigger_type == "schedule"))
    assert built_in.configuration == %{"built_in" => true}
    assert Automations.default_trigger?(definition, built_in)

    assert {:ok, renamed} =
             Automations.update_trigger(built_in, %{label: "Renamed by the maintainer"})

    assert {:ok, extra} =
             Automations.create_trigger(
               definition,
               PtcManager.Automations.Schedule.new_trigger_attrs()
             )

    refute Automations.default_trigger?(definition, extra)

    assert :ok = Automations.ensure_defaults(repository)

    schedules =
      Automations.get_definition(repository, "daily_digest").triggers
      |> Enum.filter(&(&1.trigger_type == "schedule"))

    assert Enum.map(schedules, & &1.id) |> Enum.sort() == Enum.sort([renamed.id, extra.id])

    assert {:ok, _deleted} = Automations.delete_trigger(extra)

    assert Automations.trigger_summary(Automations.get_definition(repository, "daily_digest")) ==
             "Every day at 02:00 · Run now"

    assert Automations.slug_key(repository, "Daily digest") == "daily_digest_2"
    assert Automations.slug_key(repository, "2 Fast & Furious") == "automation_2_fast_furious"
  end

  test "manual repository actions create one immutable invocation per occurrence" do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")
    trigger = Enum.find(definition.triggers, &(&1.trigger_type == "manual"))

    assert {:ok, invocation} =
             Automations.run_trigger(trigger, "maintainer", occurrence_key: "manual:test-1")

    assert invocation.automation_definition_version_id == definition.current_version.id
    assert invocation.agent_action_id
    assert invocation.occurrence_key == "manual:test-1"

    [queued_action] = PtcManager.Operations.list_queued_agent_actions()
    assert queued_action.id == invocation.agent_action_id
    assert queued_action.automation_definition_version.queue_lane == "planning"
    assert PtcManager.Operations.planning_agent_action?(queued_action)

    assert {:ok, same} =
             Automations.run_trigger(trigger, "maintainer", occurrence_key: "manual:test-1")

    assert same.id == invocation.id
    assert Repo.aggregate(Invocation, :count) == 1
  end

  test "schedule tick materializes a due occurrence and advances the trigger" do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")
    schedule = Enum.find(definition.triggers, &(&1.trigger_type == "schedule"))
    due = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    schedule =
      schedule
      |> Trigger.changeset(%{enabled: true, next_run_at: due})
      |> Repo.update!()

    assert :ok = PtcManager.Automations.ScheduleTickWorker.perform(%Oban.Job{})
    invocation = Repo.one!(Invocation)
    assert invocation.automation_trigger_id == schedule.id
    assert invocation.occurrence_key == DateTime.to_iso8601(due)

    advanced = Repo.get!(Trigger, schedule.id)
    assert DateTime.compare(advanced.next_run_at, due) == :gt
  end

  test "an invented Herdr kind completes the generic result contract without model-specific code" do
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    previous_command = Application.get_env(:ptc_manager, :generic_herdr_command)
    previous_profiles = Application.get_env(:ptc_manager, :agent_profiles)

    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :generic_herdr_command, GenericHerdrCommand)

    Application.put_env(:ptc_manager, :agent_profiles, %{
      "test-maintainer" => %{
        "enabled" => true,
        "args" => ["--fixture", "{{workspace_path}}", "{{workspace_path_toml}}"]
      }
    })

    on_exit(fn ->
      Application.put_env(:ptc_manager, :dispatch_enabled, previous_dispatch)
      Application.put_env(:ptc_manager, :generic_herdr_command, previous_command)
      Application.put_env(:ptc_manager, :agent_profiles, previous_profiles)
    end)

    repository = repository_fixture(%{github_name: "ptc_runner", local_path: System.tmp_dir!()})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")

    attrs =
      definition.current_version
      |> Map.from_struct()
      |> Map.take([
        :target_type,
        :execution_profile,
        :github_access,
        :queue_lane,
        :resource_class,
        :lock_policy,
        :timeout_seconds,
        :result_type,
        :result_protocol_version,
        :prompt,
        :configuration_snapshot
      ])
      |> Map.put(:prompt, String.duplicate("Long context line.\n", 1_000))
      |> Map.put(:agent_selector, %{
        "mode" => "require",
        "preferred_kind" => "test-maintainer",
        "required_capabilities" => []
      })

    assert {:ok, version} = Automations.create_version(definition, attrs, "test")
    trigger = Automations.get_definition(repository, definition.key).triggers |> hd()
    assert {:ok, invocation} = Automations.run_trigger(trigger, "maintainer")

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    incarnation = PtcManager.RuntimeIncarnation.current()

    assert {:ok, _worker} =
             PtcManager.Operations.create_worker(%{
               worker_key: "herdr:default",
               name: "Herdr default",
               status: "online",
               capabilities: %{"herdr" => true},
               last_heartbeat_at: now,
               worker_incarnation_id: "worker-test",
               herdr_incarnation_id: "herdr-test",
               coordinator_incarnation_id: incarnation
             })

    assert {:ok, {action, _token}} =
             PtcManager.Operations.claim_agent_action(invocation.agent_action_id)

    assert action.automation_definition_version_id == version.id

    assert {:ok, %{"outcome" => "no-changes"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    invocation = Repo.get!(Invocation, invocation.id)
    assert invocation.selected_agent_kind == "test-maintainer"
    assert invocation.selected_agent_name == "automation_a#{action.id}_f1"

    [run] = PtcManager.Operations.list_active_agent_runs()
    assert run.agent_name == invocation.selected_agent_name
    assert run.herdr_workspace == "generic-workspace"
  end

  test "a snapshot is Git-trusted before Herdr opens it and trust is revoked after" do
    keys = [
      :dispatch_enabled,
      :generic_herdr_command,
      :agent_profiles,
      :herdr_run_as_user,
      :worktree_root,
      :planning_snapshot_root,
      :worker_repository_trust_command,
      :worker_claude_trust_command,
      :worker_claude_trust_test_pid,
      :worker_agent_login_command
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :generic_herdr_command, GenericHerdrCommand)
    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")
    Application.put_env(:ptc_manager, :worker_repository_trust_command, GitTrustCommand)
    # The fixture repository is the temporary directory itself, so its parent
    # plays the managed root that makes the workspace eligible for trust.
    Application.put_env(
      :ptc_manager,
      :worktree_root,
      System.tmp_dir!() |> Path.expand() |> Path.dirname()
    )

    Application.put_env(
      :ptc_manager,
      :planning_snapshot_root,
      System.tmp_dir!() |> Path.expand() |> Path.dirname()
    )

    Application.put_env(:ptc_manager, :worker_claude_trust_command, ClaudeTrustCommand)
    Application.put_env(:ptc_manager, :worker_claude_trust_test_pid, self())
    Application.put_env(:ptc_manager, :worker_agent_login_command, AgentLoginCommand)

    Application.put_env(:ptc_manager, :agent_profiles, %{
      "claude" => %{
        "enabled" => true,
        "args" => [
          "--dangerously-skip-permissions",
          "{{workspace_path}}",
          "{{workspace_path_toml}}"
        ]
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    repository = repository_fixture(%{github_name: "ptc_runner", local_path: System.tmp_dir!()})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")

    attrs =
      definition.current_version
      |> Map.from_struct()
      |> Map.take([
        :target_type,
        :execution_profile,
        :github_access,
        :queue_lane,
        :resource_class,
        :lock_policy,
        :timeout_seconds,
        :result_type,
        :result_protocol_version,
        :prompt,
        :configuration_snapshot
      ])
      |> Map.put(:prompt, String.duplicate("Long context line.\n", 1_000))
      |> Map.put(:agent_selector, %{
        "mode" => "require",
        "preferred_kind" => "claude",
        "required_capabilities" => []
      })

    assert {:ok, _version} = Automations.create_version(definition, attrs, "test")
    trigger = Automations.get_definition(repository, definition.key).triggers |> hd()
    assert {:ok, invocation} = Automations.run_trigger(trigger, "maintainer")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _worker} =
             PtcManager.Operations.create_worker(%{
               worker_key: "herdr:default",
               name: "Herdr default",
               status: "online",
               capabilities: %{"herdr" => true},
               last_heartbeat_at: now,
               worker_incarnation_id: "worker-test",
               herdr_incarnation_id: "herdr-test",
               coordinator_incarnation_id: PtcManager.RuntimeIncarnation.current()
             })

    assert {:ok, {action, _token}} =
             PtcManager.Operations.claim_agent_action(invocation.agent_action_id)

    assert {:ok, %{"outcome" => "no-changes"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    workspace_path = Process.get({GenericHerdrCommand, :workspace_path})
    assert is_binary(workspace_path)
    assert_receive {:workspace_event, first_event}

    assert first_event ==
             {:git, ["config", "--global", "--add", "safe.directory", workspace_path]}

    assert_receive {:workspace_event, :open}

    assert_receive {:workspace_event,
                    {:git,
                     [
                       "config",
                       "--global",
                       "--fixed-value",
                       "--unset-all",
                       "safe.directory",
                       ^workspace_path
                     ]}}

    assert_receive {:claude_trust, ["allow", ^workspace_path]}
    assert_receive {:claude_trust, ["revoke", ^workspace_path]}
    assert Repo.get!(Invocation, invocation.id).selected_agent_kind == "claude"

    Application.put_env(:ptc_manager, :generic_herdr_command, RejectedOpenCommand)

    assert {:error, :open_failed} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    assert_receive {:workspace_event,
                    {:git, ["config", "--global", "--add", "safe.directory", ^workspace_path]}}

    assert_receive {:workspace_event, :rejected_open}

    assert_receive {:workspace_event,
                    {:git,
                     [
                       "config",
                       "--global",
                       "--fixed-value",
                       "--unset-all",
                       "safe.directory",
                       ^workspace_path
                     ]}}
  end

  test "agent profile workspace placeholders preserve one argument and quote TOML paths" do
    assert ["--cwd=/tmp/a b", ~s(projects={"/tmp/a b"={trust_level="trusted"}})] ==
             PtcManager.AgentProfiles.expand_args(
               [
                 "--cwd={{workspace_path}}",
                 ~s(projects={{{workspace_path_toml}}={trust_level="trusted"}})
               ],
               "/tmp/a b"
             )
  end

  defp claimed_investigation_fixture! do
    previous_command = Application.get_env(:ptc_manager, :generic_herdr_command)
    previous_profiles = Application.get_env(:ptc_manager, :agent_profiles)
    previous_setup = Application.get_env(:ptc_manager, :workspace_setup)
    previous_root = Application.get_env(:ptc_manager, :worktree_root)
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    previous_cleanup_git = Application.get_env(:ptc_manager, :investigation_cleanup_git)
    Process.put(:investigation_test_pid, self())

    root = Path.join(System.tmp_dir!(), "ptc-investigation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(:ptc_manager, :generic_herdr_command, InvestigationHerdrCommand)
    Application.put_env(:ptc_manager, :workspace_setup, InvestigationWorkspaceSetup)
    Application.put_env(:ptc_manager, :worktree_root, root)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :investigation_cleanup_git, InvestigationCleanupGit)

    Application.put_env(:ptc_manager, :agent_profiles, %{
      "codex" => %{"enabled" => true, "args" => ["--fixture", "{{workspace_path}}"]}
    })

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env(:generic_herdr_command, previous_command)
      restore_env(:agent_profiles, previous_profiles)
      restore_env(:workspace_setup, previous_setup)
      restore_env(:worktree_root, previous_root)
      restore_env(:dispatch_enabled, previous_dispatch)
      restore_env(:investigation_cleanup_git, previous_cleanup_git)
    end)

    repository = repository_fixture(%{github_name: "ptc_runner", local_path: System.tmp_dir!()})
    issue = issue_fixture(repository, %{number: 91})
    assert {:ok, queued} = MaintainerActions.enqueue("review_issue", issue.id, "maintainer")
    source_sha = String.duplicate("a", 40)

    action =
      queued
      |> PtcManager.Operations.AgentAction.changeset(%{
        target_snapshot: %{"source_sha" => source_sha, "source_path" => "/read-only/evidence"}
      })
      |> Repo.update!()

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _worker} =
             PtcManager.Operations.create_worker(%{
               worker_key: "herdr:default",
               name: "Herdr default",
               status: "online",
               capabilities: %{"herdr" => true},
               last_heartbeat_at: now,
               worker_incarnation_id: "worker-review",
               herdr_incarnation_id: "herdr-review",
               coordinator_incarnation_id: PtcManager.RuntimeIncarnation.current()
             })

    assert {:ok, {action, token}} = PtcManager.Operations.claim_agent_action(action.id)

    %{action: action, issue: issue, root: root, source_sha: source_sha, token: token}
  end

  defp retried_investigation_fixture! do
    %{action: action, root: root} = claimed_investigation_fixture!()
    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    {:ok, identity} = PtcManager.Repository.InvestigationWorkspace.identity(action)
    path = PtcManager.Repository.InvestigationWorkspace.path(root, action.repository, action)

    old_run =
      run
      |> PtcManager.Operations.AgentRun.changeset(%{
        state: "lost",
        ended_at: DateTime.utc_now(),
        disposable_cleanup_state: "workspace_open",
        disposable_worktree_path: path,
        disposable_worktree_branch: identity.branch,
        herdr_workspace: "old-workspace"
      })
      |> Repo.update!()

    next =
      action
      |> PtcManager.Operations.AgentAction.changeset(%{attempt_count: action.attempt_count + 1})
      |> Repo.update!()

    {:ok, next_identity} = PtcManager.Repository.InvestigationWorkspace.identity(next)
    next_path = PtcManager.Repository.InvestigationWorkspace.path(root, action.repository, next)

    new_run =
      %PtcManager.Operations.AgentRun{}
      |> PtcManager.Operations.AgentRun.changeset(%{
        worker_id: run.worker_id,
        agent_action_id: action.id,
        role: "manager",
        state: "working",
        fencing_token: next.attempt_count,
        started_at: run.started_at,
        last_heartbeat_at: run.last_heartbeat_at,
        disposable_cleanup_state: "workspace_open",
        disposable_worktree_path: next_path,
        disposable_worktree_branch: next_identity.branch,
        herdr_workspace: "new-workspace"
      })
      |> Repo.insert!()

    %{action: action, old_run: old_run, new_run: new_run}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
