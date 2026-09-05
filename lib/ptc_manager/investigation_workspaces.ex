defmodule PtcManager.InvestigationWorkspaces do
  @moduledoc "Durably removes disposable issue-review worktrees and their branches."

  import Ecto.Query

  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Gateway
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, AgentRun}
  alias PtcManager.Repo
  alias PtcManager.Repository.{Checkout, InvestigationWorkspace, WorkerGit}
  alias PtcManager.WorktreeSecurity

  @terminal_action_states ~w(sync_pending done failed cancelled)

  def cleanup(
        %AgentAction{id: action_id, attempt_count: attempt},
        remove_workspace,
        git \\ nil,
        workspace_hint \\ nil,
        recover_workspace \\ nil
      )
      when is_function(remove_workspace, 1) and
             (is_nil(recover_workspace) or is_function(recover_workspace, 3)) do
    git = git || configured_git()

    action_id
    |> cleanup_run_for_action(attempt)
    |> case do
      nil -> {:ok, :empty}
      run -> cleanup_run(run, remove_workspace, git, workspace_hint, recover_workspace)
    end
  end

  def cleanup_terminal_once(adapter \\ HerdrAdapter, git \\ nil) do
    git = git || configured_git()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    candidate =
      AgentRun
      |> join(:inner, [run], action in AgentAction, on: action.id == run.agent_action_id)
      |> where(
        [run, action],
        not is_nil(run.disposable_cleanup_state) and action.state in ^@terminal_action_states and
          (is_nil(run.disposable_cleanup_token) or
             is_nil(run.disposable_cleanup_expires_at) or
             run.disposable_cleanup_expires_at <= ^now)
      )
      |> order_by([run], asc: run.updated_at, asc: run.id)
      |> preload([run, action],
        agent_action: {action, [:repository, :automation_definition_version]}
      )
      |> limit(1)
      |> Repo.one()

    case candidate do
      nil ->
        {:ok, :empty}

      run ->
        cleanup_run(
          run,
          &Gateway.call(adapter, :remove_action_workspace, [&1]),
          git,
          nil,
          &Gateway.call(adapter, :open_action_workspace, [&1, &2, &3])
        )
    end
  end

  defp cleanup_run_for_action(action_id, attempt) do
    AgentRun
    |> join(:inner, [run], action in AgentAction, on: action.id == run.agent_action_id)
    |> where(
      [run, action],
      action.id == ^action_id and run.fencing_token == ^attempt and
        not is_nil(run.disposable_cleanup_state)
    )
    |> order_by([run], desc: run.id)
    |> preload([run, action],
      agent_action: {action, [:repository, :automation_definition_version]}
    )
    |> limit(1)
    |> Repo.one()
  end

  defp cleanup_run(%AgentRun{} = run, remove_workspace, git, workspace_hint, recover_workspace) do
    case Operations.claim_disposable_workspace_cleanup(run.id) do
      {:ok, claimed, token} ->
        cleanup_claimed(
          claimed,
          token,
          remove_workspace,
          git,
          workspace_hint,
          recover_workspace
        )

      {:error, :disposable_workspace_cleanup_already_claimed} = error ->
        error
    end
  end

  defp cleanup_claimed(
         run,
         token,
         remove_workspace,
         git,
         workspace_hint,
         recover_workspace
       ) do
    result =
      with {:ok, identity} <- cleanup_identity(run),
           {:ok, run} <-
             remove_workspace_if_needed(
               run,
               identity,
               remove_workspace,
               git,
               token,
               workspace_hint,
               recover_workspace
             ),
           :ok <- delete_branch(run, identity, git),
           {:ok, cleaned} <- Operations.complete_disposable_workspace_cleanup(run.id, token) do
        {:ok, cleaned}
      end

    case result do
      {:ok, _cleaned} = success ->
        success

      {:error, reason} ->
        _ = Operations.fail_disposable_workspace_cleanup(run.id, token)
        {:error, {:investigation_workspace_cleanup_failed, reason}}
    end
  end

  defp cleanup_identity(%AgentRun{
         disposable_worktree_path: path,
         disposable_worktree_branch: branch,
         fencing_token: attempt,
         agent_action: %AgentAction{repository: repository} = action
       })
       when is_binary(path) and is_binary(branch) do
    root = Application.get_env(:ptc_manager, :worktree_root)
    action = %{action | attempt_count: attempt}

    with true <- is_binary(root) and root != "" and File.dir?(root),
         :ok <- WorktreeSecurity.validate_configured_root(root),
         {:ok, expected_branch} <- InvestigationWorkspace.branch(action),
         expected_path <- InvestigationWorkspace.path(root, repository, action),
         true <- Path.expand(path) == Path.expand(expected_path),
         true <- branch == expected_branch,
         {:ok, repository_path} <- Checkout.available_path(repository) do
      {:ok,
       %{
         branch: branch,
         path: Path.expand(path),
         repository_path: repository_path,
         label: "review-issue-#{action.target_id}"
       }}
    else
      _invalid -> {:error, :invalid_investigation_cleanup_identity}
    end
  end

  defp cleanup_identity(_run), do: {:error, :invalid_investigation_cleanup_identity}

  defp remove_workspace_if_needed(
         %AgentRun{disposable_cleanup_state: "workspace_open", herdr_workspace: workspace} = run,
         identity,
         remove_workspace,
         git,
         token,
         _workspace_hint,
         _recover_workspace
       )
       when is_binary(workspace) and workspace != "" do
    with :ok <- remove_workspace_idempotently(remove_workspace, workspace, identity, git),
         {:ok, transitioned} <-
           Operations.advance_disposable_workspace_cleanup(
             run.id,
             token,
             "workspace_open",
             "branch_pending"
           ) do
      {:ok, transitioned}
    end
  end

  defp remove_workspace_if_needed(
         %AgentRun{disposable_cleanup_state: "planned"} = run,
         identity,
         remove_workspace,
         git,
         token,
         workspace_hint,
         recover_workspace
       ) do
    removal =
      remove_planned_workspace(
        run,
        identity,
        remove_workspace,
        git,
        workspace_hint,
        recover_workspace
      )

    with :ok <- removal,
         {:ok, transitioned} <-
           Operations.advance_disposable_workspace_cleanup(
             run.id,
             token,
             "planned",
             "branch_pending"
           ) do
      {:ok, transitioned}
    end
  end

  defp remove_workspace_if_needed(
         %AgentRun{disposable_cleanup_state: "branch_pending"} = run,
         _identity,
         _remove_workspace,
         _git,
         _token,
         _workspace_hint,
         _recover_workspace
       ),
       do: {:ok, run}

  defp remove_workspace_if_needed(
         _run,
         _identity,
         _remove_workspace,
         _git,
         _token,
         _workspace_hint,
         _recover_workspace
       ),
       do: {:error, :invalid_investigation_cleanup_state}

  defp remove_planned_workspace(_run, identity, remove_workspace, git, workspace_hint, _recover)
       when is_binary(workspace_hint) and workspace_hint != "" do
    remove_workspace_idempotently(remove_workspace, workspace_hint, identity, git)
  end

  defp remove_planned_workspace(
         _run,
         %{path: path, repository_path: repository_path, label: label} = identity,
         remove_workspace,
         git,
         _workspace_hint,
         recover_workspace
       )
       when is_function(recover_workspace, 3) do
    if File.exists?(path) do
      with {:ok, workspace} <- recover_workspace.(repository_path, path, label) do
        remove_workspace_idempotently(remove_workspace, workspace, identity, git)
      end
    else
      :ok
    end
  end

  defp remove_planned_workspace(
         _run,
         identity,
         _remove_workspace,
         git,
         _workspace_hint,
         _recover_workspace
       ),
       do: remove_unconfirmed_worktree(identity, git)

  defp remove_workspace_idempotently(remove_workspace, workspace, identity, git) do
    case remove_workspace.(workspace) do
      :ok ->
        remove_unconfirmed_worktree(identity, git)

      {:error, :workspace_not_found} ->
        remove_unconfirmed_worktree(identity, git)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_unconfirmed_worktree(%{path: path, repository_path: repository_path}, git) do
    if File.exists?(path) do
      case git.run(["-C", repository_path, "worktree", "remove", "--force", "--", path]) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:unconfirmed_worktree_remove_failed, status, bounded(output)}}
      end
    else
      :ok
    end
  end

  defp delete_branch(
         %AgentRun{disposable_cleanup_state: state},
         %{repository_path: repository_path, branch: branch},
         git
       )
       when state in ["planned", "workspace_open", "branch_pending"] do
    case git.run([
           "-C",
           repository_path,
           "update-ref",
           "-d",
           "refs/heads/#{branch}"
         ]) do
      {_output, 0} ->
        :ok

      {output, status} ->
        if branch_absent?(git, repository_path, branch) do
          :ok
        else
          {:error, {:investigation_branch_remove_failed, status, bounded(output)}}
        end
    end
  end

  defp branch_absent?(git, repository_path, branch) do
    match?(
      {_output, 1},
      git.run([
        "-C",
        repository_path,
        "show-ref",
        "--verify",
        "--quiet",
        "refs/heads/#{branch}"
      ])
    )
  end

  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)

  defp configured_git,
    do: Application.get_env(:ptc_manager, :investigation_cleanup_git, WorkerGit)
end
