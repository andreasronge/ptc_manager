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

  def sync_action(%{action_key: "post_cancellation_note"} = action, _result) do
    issue = Repo.get!(Issue, action.target_id) |> Repo.preload(:repository)
    client = Application.fetch_env!(:ptc_manager, :github_client)

    if function_exported?(client, :cancellation_comment_present?, 3),
      do:
        client.cancellation_comment_present?(
          issue.repository,
          issue.number,
          action.target_snapshot["approved_comment"]
        ),
      else: {:error, :comment_verification_unavailable}
  end

  def sync_action(action, _result), do: sync_action(action)

  defp sync_repair(%{target_id: publication_id} = action, phase) do
    publication =
      PrPublication
      |> Repo.get!(publication_id)
      |> Repo.preload([:repository, job: [:issue, :repository, :worktree_allocation]])

    client = Application.fetch_env!(:ptc_manager, :pull_request_client)

    case client.status(publication) do
      {:ok, result} ->
        case reconcile_repair_status(action, publication, result, phase) do
          {:terminal_error, :database_busy} -> {:error, :database_busy}
          outcome -> outcome
        end

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
        {:error, :publication_not_open} -> settled_merged_repair(publication, result)
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

  # Where a repair ran decides what can be trusted afterwards. A retained session
  # produced its commit in the worktree being inspected, so the range can be
  # verified locally. A fresh worktree has no such history, so the only evidence
  # is the head the agent pushed matching what GitHub reports.
  defp reconcile_repair_status(
         action,
         publication,
         %{state: "open"} = result,
         {:postflight, execution_result} = postflight
       ) do
    if fresh_repair?(action, publication),
      do: reconcile_fresh_repair(action, publication, result, execution_result),
      else: reconcile_retained_repair(action, publication, result, postflight)
  end

  defp fresh_repair?(%{target_snapshot: %{"repair_mode" => mode}}, _publication),
    do: mode == "fresh"

  # Actions recorded before repair mode existed keep the behaviour they ran under.
  defp fresh_repair?(_action, publication), do: PrPublication.external?(publication)

  defp reconcile_fresh_repair(
         action,
         publication,
         %{state: "open", head_sha: head_sha} = result,
         execution_result
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

  defp reconcile_retained_repair(
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

  defp reconcile_retained_repair(
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
    with {:ok, verified} <- verify_retained_repair(action, publication, result) do
      Publications.record_repaired_status(publication.id, result, verified)
    end
  end

  defp verify_retained_repair(action, publication, result) do
    job = publication.job

    with {:ok, path} <- repair_path(job),
         {:ok, verified} <- verify_repair_range(job, path, result.base_sha),
         true <- verified.head_sha == result.head_sha,
         :ok <- GitProbe.descendant?(path, preflight_head(action), verified.head_sha),
         :ok <- GitProbe.reclaimable(path, job.branch_name, verified.head_sha) do
      {:ok, verified}
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

  defp mark_repair_attention(_publication, :database_busy), do: :ok

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

  # Reconciliation may finish first, but its mutable remote head is not repair
  # evidence. Validate the action's head independently before accepting its state.
  defp settled_merged_repair(publication, result) do
    repository = PrPublication.repository(publication)

    case Repo.get(PrPublication, publication.id) do
      %PrPublication{state: "published", pr_state: "merged"} = settled ->
        if settled.remote_head_sha == result.head_sha and settled.pr_url == result.pr_url and
             result.base_ref == repository.default_branch and
             String.downcase(result.base_repository) ==
               String.downcase("#{repository.github_owner}/#{repository.github_name}") do
          {:ok, %{pull_request: result, publication: settled}}
        else
          {:terminal_error, :merged_repair_not_recorded}
        end

      _publication ->
        {:terminal_error, :publication_not_open}
    end
  end

  defp merged_repair_matches?(action, publication, result) do
    if fresh_repair?(action, publication),
      do:
        is_binary(repair_intended_head(action)) and
          repair_intended_head(action) == result.head_sha,
      else: true
  end

  defp prepare_merged_repair(action, publication, result) do
    cond do
      fresh_repair?(action, publication) ->
        {:ok, publication}

      is_binary(preflight_head(action)) and result.head_sha == preflight_head(action) ->
        {:ok, publication}

      true ->
        with {:ok, verified} <- verify_retained_repair(action, publication, result) do
          if publication.pr_state == "merged" do
            {:ok, publication}
          else
            Publications.record_repaired_status(
              publication.id,
              Map.put(result, :state, "open"),
              verified
            )
          end
        end
    end
  end

  defp repair_visibility_sync_limit do
    Application.get_env(:ptc_manager, :repair_visibility_sync_limit, 8)
  end
end
