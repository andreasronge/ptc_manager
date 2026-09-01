defmodule PtcManager.MaintainerActions.Sync do
  @moduledoc "Reconciles the canonical GitHub target after every maintainer-action attempt."

  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.GitHub.AppBroker
  alias PtcManager.Operations
  alias PtcManager.Operations.{Issue, PrPublication}
  alias PtcManager.Publications
  alias PtcManager.Repo
  alias PtcManager.Repository.GitProbe

  def sync_action(%{target_type: "issue", target_id: issue_id}) do
    issue = Issue |> Repo.get!(issue_id) |> Repo.preload(:repository)
    GitHubSync.sync_issue(issue.repository, issue.number)
  end

  def sync_action(%{action_key: "prepare_merge_decision", target_id: publication_id}) do
    publication =
      PrPublication
      |> Repo.get!(publication_id)
      |> Repo.preload([:repository, job: [:issue, :repository]])

    client = Application.fetch_env!(:ptc_manager, :pull_request_client)

    case client.status(publication) do
      {:ok, result} ->
        case Publications.record_remote_status(publication.id, result) do
          {:ok, %{state: "published", pr_state: "open"}} when result.draft == false ->
            {:ok, %{pull_request: result}}

          {:ok, _publication} when result.draft == true ->
            {:terminal_error, :pull_request_is_draft}

          {:ok, _publication} ->
            {:terminal_error, :pull_request_not_open}

          {:error, :publication_not_open} ->
            {:terminal_error, :pull_request_not_open}

          {:error, reason} ->
            {:error, reason}
        end

      {:retry, reason} ->
        {:error, reason}

      {:blocked, reason} ->
        {:terminal_error, reason}

      other ->
        {:error, {:unexpected_status_result, other}}
    end
  end

  def sync_action(%{action_key: action_key} = action)
      when action_key in ["repair_pr", "repair_and_merge_pr"],
      do: sync_repair(action, :preflight)

  def sync_action(%{action_key: action_key, repository: repository})
      when action_key in ["pr_retrospective", "create_retrospective_issue"] do
    GitHubSync.sync_repository(repository)
  end

  def sync_action(%{target_type: "repository", repository: repository}),
    do: GitHubSync.sync_repository(repository)

  def sync_action(%{action_key: action_key} = action, result)
      when action_key in ["repair_pr", "repair_and_merge_pr"],
      do: sync_repair(action, {:postflight, result})

  def sync_action(action, _result), do: sync_action(action)

  defp sync_repair(%{target_id: publication_id} = action, phase) do
    publication =
      PrPublication
      |> Repo.get!(publication_id)
      |> Repo.preload([:repository, job: [:issue, :repository, :worktree_allocation]])

    client = Application.fetch_env!(:ptc_manager, :pull_request_client)

    case client.status(publication) do
      {:ok, result} ->
        reconcile_repair_status(action, publication, result, phase)

      {:retry, reason} ->
        {:error, reason}

      {:blocked, reason} ->
        if match?({:postflight, _}, phase), do: mark_repair_attention(publication, reason)
        {:terminal_error, reason}

      other ->
        {:error, {:unexpected_status_result, other}}
    end
  end

  defp reconcile_repair_status(_action, publication, result, :preflight) do
    case Publications.record_remote_status(publication.id, result) do
      {:ok, %{state: "published", pr_state: "open"}} ->
        {:ok, %{pull_request: result}}

      {:ok, _publication} ->
        {:terminal_error, :pull_request_not_open}

      {:error, :publication_not_open} ->
        {:terminal_error, :pull_request_not_open}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_repair_status(
         %{action_key: "repair_and_merge_pr"} = action,
         publication,
         %{state: "merged"} = result,
         {:postflight, {:ok, %{"outcome" => "repaired"}}}
       ) do
    if merged_repair_matches?(action, publication, result) do
      with {:ok, prepared} <- prepare_merged_repair(action, publication, result),
           {:ok, %{state: "published", pr_state: "merged"} = updated} <-
             Publications.record_remote_status(prepared.id, result) do
        {:ok, %{pull_request: result, publication: updated}}
      else
        {:ok, _unexpected} -> {:terminal_error, :merged_repair_not_recorded}
        {:error, reason} -> {:terminal_error, reason}
      end
    else
      {:terminal_error, :unexpected_repair_head_change}
    end
  end

  defp reconcile_repair_status(_action, publication, %{state: state} = result, {:postflight, _})
       when state in ["merged", "closed"] do
    case Publications.record_remote_status(publication.id, result) do
      {:ok, _publication} -> {:terminal_error, :pull_request_not_open}
      {:error, reason} -> {:terminal_error, reason}
    end
  end

  defp reconcile_repair_status(
         action,
         %PrPublication{source: "external", job_id: nil} = publication,
         %{state: "open", head_sha: head_sha} = result,
         {:postflight, execution_result}
       ) do
    intended_head = repair_intended_head(action)

    cond do
      is_binary(intended_head) and head_sha == intended_head ->
        case Publications.record_remote_status(publication.id, result) do
          {:ok, updated} ->
            if action.action_key == "repair_and_merge_pr",
              do: {:error, :authorized_merge_not_finished},
              else: {:ok, %{pull_request: result, publication: updated}}

          {:error, reason} ->
            {:terminal_error, reason}
        end

      is_binary(intended_head) and head_sha == preflight_head(action) and
          action.sync_attempt_count < repair_visibility_sync_limit() ->
        {:error, :repair_head_not_visible}

      is_binary(intended_head) and head_sha == preflight_head(action) ->
        {:terminal_error, :repair_head_visibility_timeout}

      is_binary(intended_head) ->
        {:terminal_error, :unexpected_repair_head_change}

      match?({:error, _reason}, execution_result) ->
        {:terminal_error, {:repair_execution_failed, elem(execution_result, 1)}}

      match?({:ok, %{"outcome" => "repair-blocked"}}, execution_result) ->
        case Publications.record_remote_status(publication.id, result) do
          {:ok, updated} -> {:ok, %{pull_request: result, publication: updated}}
          {:error, reason} -> {:terminal_error, reason}
        end

      action.action_key == "repair_and_merge_pr" ->
        case Publications.record_remote_status(publication.id, result) do
          {:ok, _updated} -> {:error, :authorized_merge_not_finished}
          {:error, reason} -> {:terminal_error, reason}
        end

      true ->
        case Publications.record_remote_status(publication.id, result) do
          {:ok, updated} -> {:ok, %{pull_request: result, publication: updated}}
          {:error, reason} -> {:terminal_error, reason}
        end
    end
  end

  defp reconcile_repair_status(
         action,
         publication,
         %{state: "open", head_sha: head_sha} = result,
         {:postflight, {:ok, %{"outcome" => "repaired"}}}
       ) do
    if head_sha == preflight_head(action) do
      reconcile_unobserved_repair(action, publication)
    else
      case record_verified_repair(action, publication, result) do
        {:ok, _publication} ->
          if action.action_key == "repair_and_merge_pr",
            do: {:error, :authorized_merge_not_finished},
            else: {:ok, %{pull_request: result}}

        {:error, :repair_base_missing} ->
          if action.sync_attempt_count >= repair_visibility_sync_limit() do
            mark_repair_attention(publication, :repair_base_visibility_timeout)
            {:terminal_error, :repair_base_visibility_timeout}
          else
            {:error, :repair_base_missing}
          end

        {:error, reason} ->
          mark_repair_attention(publication, reason)
          {:terminal_error, reason}
      end
    end
  end

  defp reconcile_repair_status(
         action,
         publication,
         %{state: "open", head_sha: head_sha} = result,
         {:postflight, execution_result}
       ) do
    if head_sha == preflight_head(action) do
      case execution_result do
        {:error, _reason} ->
          {:terminal_error, :repair_execution_uncertain}

        _settled_result ->
          case release_unchanged_repair(publication, result) do
            {:ok, _publication} ->
              {:ok, %{pull_request: result}}

            {:error, reason} ->
              mark_repair_attention(publication, reason)
              {:terminal_error, reason}
          end
      end
    else
      mark_repair_attention(publication, :unexpected_repair_head_change)

      case execution_result do
        {:ok, %{"outcome" => "repair-blocked"}} ->
          {:terminal_error, :repair_blocked_after_push}

        _execution_result ->
          {:terminal_error, :unexpected_repair_head_change}
      end
    end
  end

  defp record_verified_repair(action, publication, result) do
    job = publication.job

    with {:ok, path} <- repair_path(job),
         {:ok, verified} <- verify_repair_range(job, path, result.base_sha),
         true <- verified.head_sha == result.head_sha,
         :ok <- GitProbe.descendant?(path, preflight_head(action), verified.head_sha),
         :ok <- GitProbe.reclaimable(path, job.branch_name, verified.head_sha) do
      Publications.record_repaired_status(publication.id, result, verified)
    else
      false -> {:error, :repair_head_not_verified}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_repair_range(job, path, base_sha) do
    case GitProbe.verify_repair_at(job.repository, job, path, base_sha) do
      {:error, :repair_base_missing} ->
        fetcher = Application.get_env(:ptc_manager, :repair_base_fetcher, AppBroker)

        case fetcher.fetch_base_for_verification(path, job.repository, base_sha) do
          :ok -> GitProbe.verify_repair_at(job.repository, job, path, base_sha)
          {:retry, _reason} -> {:error, :repair_base_missing}
          {:blocked, reason} -> {:error, {:repair_base_fetch_blocked, reason}}
          {:error, _reason} -> {:error, :repair_base_missing}
          _other -> {:error, :repair_base_missing}
        end

      result ->
        result
    end
  end

  defp release_unchanged_repair(publication, result) do
    job = publication.job

    with {:ok, path} <- repair_path(job),
         :ok <- GitProbe.reclaimable(path, job.branch_name, result.head_sha),
         {:ok, updated} <- Publications.record_remote_status(publication.id, result),
         {:ok, _allocation} <-
           Operations.release_repair_worktree(job.id, result.head_sha, "repair-agent") do
      {:ok, updated}
    end
  end

  defp reconcile_unobserved_repair(action, publication) do
    job = publication.job

    with {:ok, path} <- repair_path(job),
         {:ok, local_head} <- GitProbe.current_job_head(path, job) do
      cond do
        local_head == preflight_head(action) ->
          mark_repair_attention(publication, :repair_agent_did_not_advance_head)
          {:terminal_error, :repair_agent_did_not_advance_head}

        action.sync_attempt_count >= repair_visibility_sync_limit() ->
          mark_repair_attention(publication, :repair_head_visibility_timeout)
          {:terminal_error, :repair_head_visibility_timeout}

        true ->
          {:error, :repair_head_not_visible}
      end
    else
      {:error, reason} ->
        mark_repair_attention(publication, reason)
        {:terminal_error, reason}
    end
  end

  defp repair_path(%{worktree_allocation: %{path: path}}) when is_binary(path) do
    if File.dir?(path),
      do: {:ok, Path.expand(path)},
      else: {:error, :repair_worktree_unavailable}
  end

  defp repair_path(_job), do: {:error, :repair_worktree_unavailable}

  defp mark_repair_attention(%{job: %{worktree_allocation: %{id: id}}}, reason) do
    _ = Operations.mark_worktree_attention(id, reason, "repair-agent")
    :ok
  end

  defp mark_repair_attention(_publication, _reason), do: :ok

  defp preflight_head(%{target_snapshot: snapshot}) do
    case snapshot["head_sha"] do
      head when is_binary(head) -> head
      _head -> nil
    end
  end

  defp repair_intended_head(%{target_snapshot: snapshot}) when is_map(snapshot) do
    case snapshot["repair_intended_head_sha"] do
      head when is_binary(head) -> head
      _head -> nil
    end
  end

  defp repair_intended_head(_action), do: nil

  defp merged_repair_matches?(action, %PrPublication{source: "external"}, result),
    do: repair_intended_head(action) == result.head_sha

  defp merged_repair_matches?(_action, _publication, _result), do: true

  defp prepare_merged_repair(_action, %PrPublication{source: "external"} = publication, _result),
    do: {:ok, publication}

  defp prepare_merged_repair(action, publication, result) do
    if result.head_sha == publication.remote_head_sha do
      {:ok, publication}
    else
      record_verified_repair(action, publication, Map.put(result, :state, "open"))
    end
  end

  defp repair_visibility_sync_limit do
    Application.get_env(:ptc_manager, :repair_visibility_sync_limit, 8)
  end
end
