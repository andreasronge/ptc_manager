defmodule PtcManager.MaintainerActions do
  @moduledoc "Queues and executes named maintainer prompts while GitHub remains canonical."

  import Ecto.Query, only: [from: 2, limit: 2, order_by: 3, preload: 2, where: 3]
  require Logger

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.Sync, as: ActionSync
  alias PtcManager.Gateway
  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.DailyDigests
  alias PtcManager.DailyDigests.Evidence, as: DailyDigestEvidence
  alias PtcManager.IssueDecision
  alias PtcManager.Manager
  alias PtcManager.MergeDecisions
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, Issue, PrPublication, Repository}
  alias PtcManager.Repo
  alias PtcManager.RepoTransaction
  alias PtcManager.Repository.SourceSnapshot
  alias PtcManager.WorktreeSecurity
  alias PtcManager.Automations

  @max_daily_digest_prompt_bytes 100_000
  @terminal_daily_digest_evidence_errors ~w(
    daily_digest_pull_request_limit_reached
    daily_digest_commit_limit_reached
    daily_digest_evidence_too_large
    unexpected_github_response
    unexpected_github_pull_request
    unexpected_github_commit_date
    invalid_github_head_sha
  )a

  def enabled?, do: Application.get_env(:ptc_manager, :agent_actions_enabled, false)

  def enqueue(action_key, issue_id, actor)
      when action_key in ["private_issue_analysis", "prepare_issue", "review_issue"] and
             is_integer(issue_id) and is_binary(actor) do
    with %Issue{} = issue <- Issue |> Repo.get(issue_id) |> Repo.preload(:repository),
         :ok <- ensure_open(issue),
         {:ok, attrs} <- Catalog.build(action_key, %{issue: issue, repository: issue.repository}) do
      enqueue_versioned(issue.repository, action_key, attrs, actor)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(action_key, publication_id, actor)
      when action_key in [
             "prepare_merge_decision",
             "pr_retrospective",
             "repair_pr",
             "repair_and_merge_pr"
           ] and
             is_integer(publication_id) and is_binary(actor) do
    RepoTransaction.immediate(fn ->
      result =
        with %PrPublication{} = publication <-
               PrPublication
               |> Repo.get(publication_id)
               |> Repo.preload([
                 :repository,
                 job: [:issue, :repository, :worktree_allocation]
               ]),
             repository when not is_nil(repository) <- PrPublication.repository(publication),
             {:ok, attrs} <-
               Catalog.build(action_key, %{
                 publication: publication,
                 issue: publication.job && publication.job.issue,
                 repository: repository
               }) do
          enqueue_versioned(repository, action_key, attrs, actor)
        else
          nil -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      case result do
        {:ok, action} -> action
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def enqueue(_action_key, _target_id, _actor), do: {:error, :unknown_agent_action}

  def enqueue_issue_decision(issue_id, source_action_id, choice, custom_answer, actor)
      when is_integer(issue_id) and is_integer(source_action_id) and is_binary(choice) and
             is_binary(custom_answer) and is_binary(actor) do
    with %Issue{} = issue <- Issue |> Repo.get(issue_id) |> Repo.preload(:repository),
         :ok <- ensure_open(issue),
         :ok <- ensure_decision_needed(issue),
         %AgentAction{
           id: ^source_action_id,
           state: "done",
           target_type: "issue",
           target_id: ^issue_id
         } = source <- Repo.get(AgentAction, source_action_id),
         :ok <- ensure_latest_issue_action(source),
         :ok <- ensure_decision_source_current(source, issue),
         {:ok, source_result} <- decode_action_result(source),
         {:ok, decision} <- IssueDecision.from_result(source_result),
         {:ok, answer} <- IssueDecision.answer(decision, choice, custom_answer),
         {:ok, attrs} <-
           Catalog.build("resolve_issue_decision", %{
             issue: issue,
             repository: issue.repository,
             decision_answer: answer.value,
             source_action_id: source_action_id
           }) do
      enqueue_versioned(issue.repository, "resolve_issue_decision", attrs, actor)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :issue_decision_not_current}
    end
  end

  def enqueue_issue_decision(_issue_id, _source_action_id, _choice, _custom_answer, _actor),
    do: {:error, :decision_answer_missing}

  def enqueue_retrospective_issue(source_action_id, suggestion_index, actor)
      when is_integer(source_action_id) and is_integer(suggestion_index) and
             suggestion_index >= 0 and is_binary(actor) do
    with %AgentAction{action_key: "pr_retrospective", state: "done"} = source <-
           AgentAction |> Repo.get(source_action_id) |> Repo.preload(:repository),
         {:ok, result} <- decode_action_result(source),
         suggestions when is_list(suggestions) <- result["suggestions"],
         %{} = suggestion <- Enum.at(suggestions, suggestion_index),
         nil <- existing_suggestion_action(source, suggestion_index),
         %PrPublication{} = publication <-
           PrPublication
           |> Repo.get(source.target_id)
           |> Repo.preload(job: [:issue, :repository, :worktree_allocation]),
         {:ok, attrs} <-
           Catalog.build("create_retrospective_issue", %{
             publication: publication,
             issue: publication.job.issue,
             repository: publication.job.repository,
             suggestion: suggestion,
             source_action_id: source.id,
             suggestion_index: suggestion_index
           }) do
      enqueue_versioned(
        publication.job.repository,
        "create_retrospective_issue",
        attrs,
        actor
      )
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_suggestion}
      %AgentAction{} -> {:error, :suggestion_already_handled}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_suggestion}
    end
  end

  def enqueue_retrospective_issue(_source_action_id, _suggestion_index, _actor),
    do: {:error, :invalid_suggestion}

  defp enqueue_versioned(repository, action_key, attrs, actor) do
    with {:ok, versioned_attrs} <- Automations.snapshot_attrs(repository, action_key, attrs),
         {:ok, action} <-
           Operations.enqueue_agent_action(
             Map.merge(versioned_attrs, %{action_key: action_key, actor: actor})
           ),
         {:ok, _invocation} <-
           Automations.link_agent_action_invocation(repository, action_key, action, actor) do
      {:ok, action}
    end
  end

  def run_once(opts \\ []) do
    adapter =
      Keyword.get(
        opts,
        :adapter,
        Application.fetch_env!(:ptc_manager, :agent_action_adapter)
      )

    sync = Keyword.get(opts, :sync, ActionSync)
    lane = Keyword.get(opts, :lane, :any)
    Operations.expire_agent_action_attempts()
    if lane in [:planning, :any], do: reap_planning_worktrees()

    case Operations.next_agent_action_sync_pending_for_lane(lane) do
      nil -> execute_next(adapter, sync, lane)
      action -> reconcile_action(action, sync)
    end
  end

  defp execute_next(adapter, sync, lane) do
    case Operations.next_agent_action_candidate_for_lane(lane) do
      nil ->
        {:ok, :empty}

      candidate ->
        case prepare_and_claim(candidate, adapter, sync) do
          {:ok, {action, token}} -> execute_claimed(adapter, sync, action, token)
          {:skip, :no_longer_queued} -> {:ok, :empty}
          {:deferred, action} -> {:ok, action}
          {:terminal, action} -> {:ok, action}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp prepare_and_claim(candidate, adapter, sync) do
    lock_id = {{__MODULE__, :agent_action_preflight, candidate.id}, self()}

    case :global.trans(lock_id, fn ->
           current =
             AgentAction
             |> Repo.get(candidate.id)
             |> case do
               nil -> nil
               action -> Repo.preload(action, [:repository, :automation_definition_version])
             end

           if match?(%AgentAction{state: "queued"}, current) do
             with {:ok, prepared} <- prepare_for_execution(current, adapter, sync),
                  {:ok, {_action, _token}} = claimed <-
                    Operations.claim_agent_action(prepared.id) do
               claimed
             end
           else
             {:skip, :no_longer_queued}
           end
         end) do
      :aborted -> {:error, :agent_action_preflight_lock_failed}
      {:aborted, reason} -> {:error, {:agent_action_preflight_lock_failed, reason}}
      result -> result
    end
  end

  defp execute_claimed(adapter, sync, action, token) do
    result =
      try do
        Gateway.call(adapter, :run, [action])
      after
        release_planning_source_snapshot(action)
      end

    current_action = AgentAction |> Repo.get!(action.id) |> Repo.preload(:repository)
    sync_result = sync_after_execution(sync, current_action, result)

    case sync_result do
      {:ok, summary} ->
        settled_result = settle_repair_result(current_action, result, summary)

        Operations.complete_agent_action(
          action.id,
          token,
          store_private_analysis(current_action, settled_result, summary)
        )

      {:terminal_error, reason} ->
        Operations.complete_agent_action(
          action.id,
          token,
          {:error, {:postflight_failed, reason}}
        )

      {:error, reason} ->
        Operations.mark_agent_action_sync_pending(action.id, token, result, reason)
    end
  end

  defp prepare_for_execution(%{action_key: action_key} = action, _adapter, sync)
       when action_key in ["pr_retrospective", "create_retrospective_issue"] do
    case call_sync(sync, action) do
      {:ok, _summary} ->
        issue_numbers =
          Repo.all(
            from issue in Issue,
              where: issue.repository_id == ^action.repository_id,
              select: issue.number,
              order_by: issue.number
          )

        Operations.record_agent_action_baseline(action.id, issue_numbers)

      {:error, reason} ->
        case Operations.defer_agent_action_preflight(action.id, reason) do
          {:ok, deferred} -> {:deferred, deferred}
          {:error, defer_reason} -> {:error, defer_reason}
        end
    end
  end

  defp prepare_for_execution(%{action_key: "resolve_issue_decision"} = action, _adapter, sync) do
    case call_sync(sync, action) do
      {:ok, _summary} ->
        issue = Repo.get!(Issue, action.target_id)

        with :ok <- ensure_open(issue),
             :ok <- ensure_decision_needed(issue),
             :ok <- ensure_resolution_snapshot_current(action, issue) do
          prepare_issue_source_snapshot(action, issue)
        else
          {:error, reason} -> fail_preflight(action.id, reason)
        end

      {:terminal_error, reason} ->
        fail_preflight(action.id, reason)

      {:error, reason} ->
        case Operations.defer_agent_action_preflight(action.id, reason) do
          {:ok, deferred} -> {:deferred, deferred}
          {:error, defer_reason} -> {:error, defer_reason}
        end
    end
  end

  defp prepare_for_execution(%{action_key: action_key} = action, _adapter, sync)
       when action_key in ["private_issue_analysis", "prepare_issue", "review_issue"] do
    case call_sync(sync, action) do
      {:ok, _summary} ->
        issue = Repo.get!(Issue, action.target_id)

        case ensure_open(issue) do
          :ok -> prepare_issue_source_snapshot(action, issue)
          {:error, reason} -> fail_preflight(action.id, reason)
        end

      {:terminal_error, reason} ->
        fail_preflight(action.id, reason)

      {:error, reason} ->
        case Operations.defer_agent_action_preflight(action.id, reason) do
          {:ok, deferred} -> {:deferred, deferred}
          {:error, defer_reason} -> {:error, defer_reason}
        end
    end
  end

  defp prepare_for_execution(%{action_key: "daily_digest"} = action, _adapter, _sync) do
    case DailyDigests.get_digest(action.target_id) do
      %{agent_action_id: action_id, published_at: nil} = digest when action_id == action.id ->
        prepare_daily_digest_source_snapshot(action, digest)

      %{published_at: %DateTime{}} ->
        fail_preflight(action.id, :daily_digest_already_published)

      nil ->
        fail_preflight(action.id, :daily_digest_not_found)

      _mismatch ->
        fail_preflight(action.id, :daily_digest_action_mismatch)
    end
  end

  defp prepare_for_execution(
         %{
           target_type: "repository",
           automation_definition_version: %{execution_profile: "generic_ephemeral"}
         } = action,
         _adapter,
         sync
       ) do
    case call_sync(sync, action) do
      {:ok, _summary} -> prepare_repository_source_snapshot(action)
      {:terminal_error, reason} -> fail_preflight(action.id, reason)
      {:error, reason} -> defer_preflight(action.id, reason, action.sync_attempt_count)
    end
  end

  defp prepare_for_execution(%{action_key: "prepare_merge_decision"} = action, _adapter, sync) do
    publication = Repo.get!(PrPublication, action.target_id)

    if PrPublication.external?(publication) do
      fail_preflight(action.id, :external_pull_request_has_no_isolated_merge_reviewer)
    else
      case call_sync(sync, action) do
        {:ok, %{pull_request: status}} ->
          Operations.record_agent_action_target_snapshot(
            action.id,
            MergeDecisions.snapshot(status)
          )

        {:ok, _summary} ->
          {:error, :pull_request_status_missing}

        {:terminal_error, reason} ->
          case Operations.fail_agent_action_preflight(action.id, reason) do
            {:ok, failed} -> {:terminal, failed}
            {:error, failure} -> {:error, failure}
          end

        {:error, reason} ->
          case Operations.defer_agent_action_preflight(action.id, reason) do
            {:ok, deferred} -> {:deferred, deferred}
            {:error, defer_reason} -> {:error, defer_reason}
          end
      end
    end
  end

  defp prepare_for_execution(%{action_key: action_key} = action, adapter, sync)
       when action_key in ["repair_pr", "repair_and_merge_pr"] do
    case call_sync(sync, action) do
      {:ok, %{pull_request: status}} ->
        if action_key == "repair_and_merge_pr" or repair_needed?(status) do
          mode = repair_mode(adapter, action)

          with {:ok, prepared} <-
                 Operations.record_agent_action_target_snapshot(
                   action.id,
                   status |> MergeDecisions.snapshot() |> Map.put("repair_mode", mode),
                   action.prompt
                 ) do
            case reserve_repair_worktree(prepared, mode) do
              {:ok, _allocation} ->
                {:ok, prepared}

              {:error, :dispatch_capacity} ->
                defer_preflight(action.id, :dispatch_capacity, action.sync_attempt_count)

              {:error, reason} ->
                if WorktreeSecurity.infrastructure_error?(reason),
                  do: defer_preflight(action.id, reason, action.sync_attempt_count),
                  else: fail_preflight(action.id, reason)
            end
          end
        else
          fail_preflight(action.id, :pull_request_no_longer_needs_repair)
        end

      {:ok, _summary} ->
        {:error, :pull_request_status_missing}

      {:terminal_error, reason} ->
        fail_preflight(action.id, reason)

      {:error, reason} ->
        case Operations.defer_agent_action_preflight(action.id, reason) do
          {:ok, deferred} -> {:deferred, deferred}
          {:error, defer_reason} -> {:error, defer_reason}
        end
    end
  end

  defp prepare_for_execution(action, _adapter, _sync), do: {:ok, action}

  @doc false
  # A managed pull request is repaired by resuming its retained implementation
  # session. When that session is gone the repair still has to be possible, so it
  # runs the way an imported pull request always has: a fresh worktree at the
  # exact head GitHub reports. Preflight decides once and records the answer, so
  # the adapter that runs and the postflight that judges the result cannot
  # disagree about which evidence applies.
  defp repair_mode(adapter, action) do
    publication = Repo.get!(PrPublication, action.target_id)

    cond do
      PrPublication.external?(publication) -> "fresh"
      retained_session_available?(adapter, action) -> "retained"
      true -> "fresh"
    end
  end

  defp retained_session_available?(adapter, action),
    do: ensure_adapter_ready(adapter, action) == :ok

  defp ensure_adapter_ready(adapter, action) do
    if ready_check_supported?(adapter),
      do: Gateway.call(adapter, :ensure_ready, [action]),
      else: :ok
  end

  # A stateful scenario adapter receives itself as the first argument, exactly
  # as PtcManager.Gateway calls it, so its readiness callback is one arity wider.
  defp ready_check_supported?(adapter) when is_atom(adapter),
    do: Code.ensure_loaded?(adapter) and function_exported?(adapter, :ensure_ready, 1)

  defp ready_check_supported?(%module{}),
    do: Code.ensure_loaded?(module) and function_exported?(module, :ensure_ready, 2)

  defp ready_check_supported?(_adapter), do: false

  defp prepare_repository_source_snapshot(action) do
    source_snapshot =
      Application.get_env(:ptc_manager, :planning_source_snapshot, SourceSnapshot)

    with {:ok, source} <-
           capture_planning_snapshot(source_snapshot, action.repository, action),
         captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond),
         snapshot =
           Map.merge(action.target_snapshot || %{}, %{
             "source_sha" => source.sha,
             "source_ref" => source.ref,
             "source_default_branch" => action.repository.default_branch,
             "source_captured_at" => DateTime.to_iso8601(captured_at)
           })
           |> maybe_put_source_path(source),
         prompt =
           action.prompt <>
             """

             <source_snapshot ref="#{source.ref}" sha="#{source.sha}" default_branch="#{action.repository.default_branch}" workspace="read_only" />
             """ do
      Operations.record_agent_action_target_snapshot(action.id, snapshot, prompt)
    else
      {:error, reason} ->
        defer_preflight(action.id, reason, action.sync_attempt_count)
    end
  end

  defp prepare_issue_source_snapshot(action, issue) do
    repository = action.repository || Repo.get!(Repository, action.repository_id)

    source_snapshot =
      Application.get_env(:ptc_manager, :planning_source_snapshot, SourceSnapshot)

    snapshot_result =
      if function_exported?(source_snapshot, :prepare, 3) do
        source_snapshot.prepare(repository, action.id, action.target_snapshot || %{})
      else
        source_snapshot.capture(repository)
      end

    with {:ok, %{sha: source_sha, ref: source_ref} = source} <- snapshot_result do
      captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      snapshot =
        Map.merge(action.target_snapshot || %{}, %{
          "source_sha" => source_sha,
          "source_ref" => source_ref,
          "source_default_branch" => repository.default_branch,
          "source_captured_at" => DateTime.to_iso8601(captured_at),
          "issue_content_digest" => issue.content_digest
        })
        |> maybe_put_source_path(source)

      prompt =
        action.prompt <>
          """

          <source_snapshot ref="#{source_ref}" sha="#{source_sha}" default_branch="#{repository.default_branch}" workspace="read_only" />
          """

      Operations.record_agent_action_target_snapshot(action.id, snapshot, prompt)
    else
      {:error, reason} ->
        case Operations.defer_agent_action_source_preflight(
               action.id,
               reason,
               action.sync_attempt_count
             ) do
          {:ok, deferred} -> {:deferred, deferred}
          {:error, defer_reason} -> {:error, defer_reason}
        end
    end
  end

  defp prepare_daily_digest_source_snapshot(action, digest) do
    repository = action.repository || Repo.get!(Repository, action.repository_id)

    evidence_source =
      Application.get_env(:ptc_manager, :daily_digest_evidence, DailyDigestEvidence)

    source_snapshot =
      Application.get_env(:ptc_manager, :planning_source_snapshot, SourceSnapshot)

    with {:ok, evidence} <- evidence_source.fetch(repository, digest),
         {:ok, %{sha: source_sha, ref: source_ref} = source} <-
           capture_planning_snapshot(source_snapshot, repository, action) do
      captured_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      snapshot =
        Map.merge(action.target_snapshot || %{}, %{
          "source_sha" => source_sha,
          "source_ref" => source_ref,
          "source_default_branch" => repository.default_branch,
          "source_captured_at" => DateTime.to_iso8601(captured_at),
          "digest_date" => Date.to_iso8601(digest.digest_date),
          "trusted_source_head_sha" => evidence["source_head_sha"],
          "trusted_change_count" => evidence["change_count"],
          "trusted_pull_request_numbers" => evidence["pull_request_numbers"]
        })
        |> maybe_put_source_path(source)

      prompt =
        action.prompt <>
          """

          <source_snapshot ref="#{source_ref}" sha="#{source_sha}" default_branch="#{repository.default_branch}" workspace="read_only" github_access="none" />
          <daily_change_manifest>
          #{Jason.encode!(evidence)}
          </daily_change_manifest>
          """

      if byte_size(prompt) <= @max_daily_digest_prompt_bytes,
        do: Operations.record_agent_action_target_snapshot(action.id, snapshot, prompt),
        else:
          reject_oversized_daily_digest_prompt(
            action,
            repository,
            source_snapshot,
            snapshot
          )
    else
      {:error, reason} ->
        handle_daily_digest_preflight_error(action, reason)
    end
  end

  defp handle_daily_digest_preflight_error(action, reason)
       when reason in @terminal_daily_digest_evidence_errors,
       do: fail_preflight(action.id, reason)

  defp handle_daily_digest_preflight_error(action, {:invalid_github_json, _reason}),
    do: fail_preflight(action.id, :invalid_github_json)

  defp handle_daily_digest_preflight_error(action, reason) do
    case Operations.defer_agent_action_source_preflight(
           action.id,
           reason,
           action.sync_attempt_count
         ) do
      {:ok, deferred} -> {:deferred, deferred}
      {:error, defer_reason} -> {:error, defer_reason}
    end
  end

  defp capture_planning_snapshot(source_snapshot, repository, action) do
    if function_exported?(source_snapshot, :prepare, 3),
      do: source_snapshot.prepare(repository, action.id, action.target_snapshot || %{}),
      else: source_snapshot.capture(repository)
  end

  defp reject_oversized_daily_digest_prompt(action, repository, source_snapshot, snapshot) do
    release_result =
      if is_binary(snapshot["source_path"]) and is_atom(source_snapshot) and
           function_exported?(source_snapshot, :release, 3) do
        source_snapshot.release(repository, action.id, snapshot)
      else
        :ok
      end

    case release_result do
      :ok ->
        fail_preflight(action.id, :daily_digest_prompt_too_large)

      {:error, _reason} ->
        # Keep the path durable so the regular failed-action reaper can retry
        # cleanup instead of orphaning a coordinator-owned snapshot.
        with {:ok, _prepared} <-
               Operations.record_agent_action_target_snapshot(action.id, snapshot) do
          fail_preflight(action.id, :daily_digest_prompt_too_large)
        end
    end
  end

  defp maybe_put_source_path(snapshot, %{path: path}) when is_binary(path),
    do: Map.put(snapshot, "source_path", path)

  defp maybe_put_source_path(snapshot, _source), do: snapshot

  defp release_planning_source_snapshot(
         %AgentAction{action_key: action_key, repository: repository} = action
       )
       when action_key in [
              "daily_digest",
              "prepare_issue",
              "review_issue",
              "resolve_issue_decision"
            ] or action.target_type == "repository" do
    source_snapshot =
      Application.get_env(:ptc_manager, :planning_source_snapshot, SourceSnapshot)

    if is_atom(source_snapshot) and function_exported?(source_snapshot, :release, 3) do
      case source_snapshot.release(repository, action.id, action.target_snapshot || %{}) do
        :ok ->
          case Operations.mark_agent_action_source_released(action.id) do
            {:ok, _released} ->
              :ok

            {:error, reason} ->
              Logger.warning("Planning worktree release record failed: #{inspect(reason)}")
          end

        {:error, reason} ->
          case Operations.record_agent_action_source_cleanup_failure(action.id, reason) do
            {:ok, _deferred} ->
              :ok

            {:error, failure} ->
              Logger.warning("Planning snapshot cleanup retry failed: #{inspect(failure)}")
          end

          Logger.warning("Planning snapshot cleanup deferred: #{inspect(reason)}")
      end
    end
  end

  defp release_planning_source_snapshot(_action), do: :ok

  defp reap_planning_worktrees do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    AgentAction
    |> where(
      [action],
      (action.target_type == "repository" or
         action.action_key in [
           "daily_digest",
           "prepare_issue",
           "review_issue",
           "resolve_issue_decision"
         ]) and
        action.state in ["sync_pending", "done", "failed"]
    )
    |> where(
      [action],
      fragment("json_type(?, '$.source_path') = 'text'", action.target_snapshot)
    )
    |> where(
      [action],
      fragment(
        "coalesce(json_extract(?, '$.source_cleanup_next_at'), '') <= ?",
        action.target_snapshot,
        ^now
      )
    )
    |> order_by([action], asc: action.updated_at, asc: action.id)
    |> limit(20)
    |> preload(:repository)
    |> Repo.all()
    |> Enum.each(&release_planning_source_snapshot/1)
  end

  defp repair_needed?(status) do
    status.checks_state == "failure" or status.mergeability == "conflicting"
  end

  defp settle_repair_result(
         %{action_key: action_key, target_snapshot: snapshot},
         {:error, _reason},
         %{pull_request: %{head_sha: head_sha}}
       )
       when action_key in ["repair_pr", "repair_and_merge_pr"] and is_map(snapshot) do
    if snapshot["repair_intended_head_sha"] == head_sha do
      {:ok,
       %{
         "outcome" => "repaired",
         "private_summary" =>
           "GitHub confirmed the exact repair commit after the local push result was uncertain.",
         "why_it_matters" => "The intended repair is on the existing pull-request branch.",
         "scope" => "small",
         "risk" => "medium",
         "technical_evidence" => "Canonical GitHub head matches the persisted repair intent.",
         "github_changes" => ["Advanced the existing pull-request branch to #{head_sha}."],
         "evidence" => [head_sha],
         "created_issue_numbers" => [],
         "suggestions" => [],
         "pushed_head_sha" => head_sha,
         "recovered_after_uncertain_push" => true
       }}
    else
      {:error, :repair_execution_uncertain}
    end
  end

  defp settle_repair_result(_action, result, _summary), do: result

  defp reserve_repair_worktree(action, "retained") do
    publication = Repo.get!(PrPublication, action.target_id)
    Operations.reserve_worktree_for_repair(publication.job_id, "repair-agent")
  end

  # A fresh repair takes no reservation: the adapter creates its own worktree, so
  # only the root it will be created under has to be sound.
  defp reserve_repair_worktree(action, "fresh") do
    publication = PrPublication |> Repo.get!(action.target_id) |> Repo.preload(:repository)

    with :ok <- HerdrAdapter.validate_pull_request_worktree_root(publication.repository) do
      {:ok, :workspace_created_by_adapter}
    end
  end

  defp fail_preflight(action_id, reason) do
    case Operations.fail_agent_action_preflight(action_id, reason) do
      {:ok, failed} -> {:terminal, failed}
      {:error, failure} -> {:error, failure}
    end
  end

  defp defer_preflight(action_id, reason, previous_attempt_count) do
    case Operations.defer_agent_action_preflight(action_id, reason, previous_attempt_count) do
      {:ok, deferred} -> {:deferred, deferred}
      {:error, defer_reason} -> {:error, defer_reason}
    end
  end

  defp sync_after_execution(sync, action, result) do
    if action.action_key == "daily_digest" do
      {:ok, %{daily_digest: true}}
    else
      cond do
        is_atom(sync) and Code.ensure_loaded?(sync) and function_exported?(sync, :sync_action, 2) ->
          Gateway.call(sync, :sync_action, [action, result])

        is_struct(sync) and function_exported?(sync.__struct__, :sync_action, 3) ->
          Gateway.call(sync, :sync_action, [action, result])

        true ->
          call_sync(sync, action)
      end
    end
  end

  defp call_sync(sync, action), do: Gateway.call(sync, :sync_action, [action])

  defp reconcile_action(action, sync) do
    execution_result = stored_execution_result(action)

    case sync_after_execution(sync, action, execution_result) do
      {:ok, summary} = synced ->
        settled_result = settle_repair_result(action, execution_result, summary)

        case store_private_analysis(action, settled_result, summary) do
          {:ok, result} ->
            Operations.complete_agent_action_sync(action.id, synced, {:ok, result})

          {:error, reason} ->
            Operations.complete_agent_action_sync(action.id, {:terminal_error, reason})
        end

      {:error, _reason} = failed ->
        Operations.complete_agent_action_sync(action.id, failed)

      {:terminal_error, reason} ->
        Operations.complete_agent_action_sync(action.id, {:terminal_error, reason})
    end
  end

  defp store_private_analysis(
         %{action_key: "daily_digest"} = action,
         {:ok, result},
         _summary
       ) do
    with :ok <- validate_daily_digest_provenance(action, result),
         {:ok, _digest} <- DailyDigests.publish(action, result) do
      {:ok, result}
    else
      {:error, reason} -> {:error, {:daily_digest_publish_failed, reason}}
    end
  end

  defp store_private_analysis(
         %{action_key: "private_issue_analysis", target_id: issue_id},
         {:ok, result},
         _summary
       ) do
    issue = Repo.get!(Issue, issue_id)

    analysis = %{
      plain_summary: result["private_summary"],
      why_it_matters: result["why_it_matters"],
      scope: result["scope"],
      risk: result["risk"],
      readiness: result["outcome"],
      technical_evidence: result["technical_evidence"]
    }

    case Manager.store_analysis(issue, analysis) do
      {:ok, _proposal} -> {:ok, result}
      {:error, reason} -> {:error, {:private_analysis_failed, reason}}
    end
  end

  defp store_private_analysis(
         %{id: action_id, action_key: action_key, target_id: issue_id},
         {:ok, result},
         _summary
       )
       when action_key in ["prepare_issue", "review_issue", "resolve_issue_decision"] do
    issue = Repo.get!(Issue, issue_id)

    analysis = %{
      plain_summary: result["private_summary"],
      why_it_matters: result["why_it_matters"],
      scope: result["scope"],
      risk: result["risk"],
      readiness: readiness(result["outcome"]),
      technical_evidence: result["technical_evidence"]
    }

    with :ok <- canonical_outcome_matches(issue, result["outcome"]),
         {:ok, _proposal} <- Manager.store_analysis(issue, analysis),
         :ok <- record_decision_source(action_id, action_key, issue, result) do
      {:ok, result}
    else
      {:error, reason} -> {:error, {:private_analysis_failed, reason}}
    end
  end

  defp store_private_analysis(
         %{
           action_key: "pr_retrospective",
           target_id: publication_id,
           repository_id: repository_id,
           baseline_issue_numbers: baseline_issue_numbers
         },
         {:ok, result},
         _summary
       ) do
    publication = Repo.get!(PrPublication, publication_id)

    case canonical_retrospective_proposal_matches(
           publication,
           repository_id,
           result["outcome"],
           result["suggestions"],
           baseline_numbers(baseline_issue_numbers)
         ) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:retrospective_validation_failed, reason}}
    end
  end

  defp store_private_analysis(
         %{
           action_key: "create_retrospective_issue",
           target_id: publication_id,
           repository_id: repository_id,
           baseline_issue_numbers: baseline_issue_numbers
         },
         {:ok, result},
         _summary
       ) do
    publication = Repo.get!(PrPublication, publication_id)

    case canonical_retrospective_matches(
           publication,
           repository_id,
           result["outcome"],
           result["created_issue_numbers"],
           baseline_numbers(baseline_issue_numbers)
         ) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:retrospective_issue_validation_failed, reason}}
    end
  end

  defp store_private_analysis(
         %{action_key: "prepare_merge_decision"} = action,
         {:ok, result},
         %{pull_request: status}
       ) do
    case MergeDecisions.store_analysis(action, result, status) do
      {:ok, _analysis} -> {:ok, result}
      {:error, reason} -> {:error, {:private_analysis_failed, reason}}
    end
  end

  defp store_private_analysis(_action, result, _summary), do: result

  defp validate_daily_digest_provenance(action, result) do
    snapshot = action.target_snapshot || %{}

    if result["source_head_sha"] == snapshot["trusted_source_head_sha"] and
         result["change_count"] == snapshot["trusted_change_count"] and
         result["pull_request_numbers"] == snapshot["trusted_pull_request_numbers"],
       do: :ok,
       else: {:error, :daily_digest_provenance_mismatch}
  end

  defp stored_execution_result(%{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _result -> {:error, :invalid_stored_agent_action_result}
    end
  end

  defp stored_execution_result(_action), do: {:error, :agent_action_execution_failed}

  defp readiness("ready"), do: "ready"
  defp readiness("blocked"), do: "needs_information"
  defp readiness("needs-decision"), do: "needs_information"
  defp readiness("reject"), do: "outdated"

  defp ensure_decision_needed(%Issue{
         workflow_label: "ptc:needs-decision",
         workflow_label_conflict: false
       }),
       do: :ok

  defp ensure_decision_needed(%Issue{}), do: {:error, :issue_decision_not_current}

  defp ensure_decision_source_current(
         %AgentAction{target_snapshot: snapshot},
         %Issue{content_digest: content_digest}
       )
       when is_map(snapshot) and is_binary(content_digest) do
    if snapshot["decision_issue_content_digest"] == content_digest,
      do: :ok,
      else: {:error, :issue_decision_not_current}
  end

  defp ensure_decision_source_current(_action, _issue),
    do: {:error, :issue_decision_not_current}

  defp ensure_resolution_snapshot_current(
         %AgentAction{target_snapshot: snapshot},
         %Issue{content_digest: content_digest}
       )
       when is_map(snapshot) and is_binary(content_digest) do
    if snapshot["issue_content_digest"] == content_digest,
      do: :ok,
      else: {:error, :issue_decision_not_current}
  end

  defp ensure_resolution_snapshot_current(_action, _issue),
    do: {:error, :issue_decision_not_current}

  defp record_decision_source(action_id, action_key, issue, %{"outcome" => "needs-decision"})
       when action_key in ["prepare_issue", "review_issue", "resolve_issue_decision"] do
    case Operations.record_agent_action_decision_digest(action_id, issue.content_digest) do
      {:ok, _action} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_decision_source(_action_id, _action_key, _issue, _result), do: :ok

  defp ensure_latest_issue_action(%AgentAction{id: action_id, target_id: issue_id}) do
    latest_id =
      Repo.one(
        from action in AgentAction,
          where: action.target_type == "issue" and action.target_id == ^issue_id,
          order_by: [desc: action.inserted_at, desc: action.id],
          limit: 1,
          select: action.id
      )

    if latest_id == action_id, do: :ok, else: {:error, :issue_decision_not_current}
  end

  defp canonical_outcome_matches(
         %Issue{state: "open", workflow_label_conflict: false, workflow_label: "ptc:ready"},
         "ready"
       ),
       do: :ok

  defp canonical_outcome_matches(
         %Issue{state: "open", workflow_label_conflict: false, workflow_label: "ptc:blocked"},
         "blocked"
       ),
       do: :ok

  defp canonical_outcome_matches(
         %Issue{
           state: "open",
           workflow_label_conflict: false,
           workflow_label: "ptc:needs-decision"
         },
         "needs-decision"
       ),
       do: :ok

  defp canonical_outcome_matches(
         %Issue{state: "closed", workflow_label_conflict: false, workflow_label: nil},
         "reject"
       ),
       do: :ok

  defp canonical_outcome_matches(issue, outcome) do
    {:error,
     {:github_outcome_mismatch,
      %{
        claimed_outcome: outcome,
        issue_state: issue.state,
        workflow_label: issue.workflow_label,
        workflow_label_conflict: issue.workflow_label_conflict
      }}}
  end

  defp canonical_retrospective_matches(
         publication,
         repository_id,
         outcome,
         issue_numbers,
         baseline_issue_numbers
       )
       when outcome in ["followups-created", "no-followups"] and is_list(issue_numbers) and
              is_list(baseline_issue_numbers) do
    current_issue_numbers =
      Repo.all(
        from issue in Issue,
          where: issue.repository_id == ^repository_id,
          select: issue.number
      )

    created_delta =
      current_issue_numbers
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(baseline_issue_numbers))

    reported_numbers = MapSet.new(issue_numbers)

    issues =
      Repo.all(
        from issue in Issue,
          where:
            issue.repository_id == ^repository_id and issue.number in ^issue_numbers and
              issue.state == "open"
      )

    exact_delta? = created_delta == reported_numbers

    outcome_matches? =
      (outcome == "no-followups" and MapSet.size(reported_numbers) == 0) or
        (outcome == "followups-created" and MapSet.size(reported_numbers) > 0)

    issues_valid? =
      length(issues) == MapSet.size(reported_numbers) and
        Enum.all?(issues, fn issue ->
          not issue.workflow_label_conflict and is_nil(issue.workflow_label) and
            links_to_pull_request?(issue.body, publication.pr_number)
        end)

    if exact_delta? and outcome_matches? and issues_valid?,
      do: :ok,
      else: {:error, :canonical_followup_issues_mismatch}
  end

  defp canonical_retrospective_matches(
         _publication,
         _repository_id,
         _outcome,
         _issue_numbers,
         _baseline_issue_numbers
       ),
       do: {:error, :canonical_followup_issues_mismatch}

  defp canonical_retrospective_proposal_matches(
         _publication,
         repository_id,
         outcome,
         suggestions,
         baseline_issue_numbers
       )
       when outcome in ["followups-proposed", "no-followups"] and is_list(suggestions) and
              is_list(baseline_issue_numbers) do
    current_issue_numbers =
      Repo.all(
        from issue in Issue,
          where: issue.repository_id == ^repository_id,
          select: issue.number
      )

    no_issues_created? = MapSet.new(current_issue_numbers) == MapSet.new(baseline_issue_numbers)

    outcome_matches? =
      (outcome == "no-followups" and suggestions == []) or
        (outcome == "followups-proposed" and suggestions != [])

    if no_issues_created? and outcome_matches?,
      do: :ok,
      else: {:error, :canonical_retrospective_proposal_mismatch}
  end

  defp canonical_retrospective_proposal_matches(
         _publication,
         _repository_id,
         _outcome,
         _suggestions,
         _baseline_issue_numbers
       ),
       do: {:error, :canonical_retrospective_proposal_mismatch}

  defp links_to_pull_request?(body, pr_number) when is_binary(body) do
    pattern =
      Regex.compile!(
        "(?:\\bPR|\\bpull request)\\s*##{pr_number}(?!\\d)|/pull/#{pr_number}(?!\\d)",
        "i"
      )

    Regex.match?(pattern, body)
  end

  defp links_to_pull_request?(_body, _pr_number), do: false

  defp baseline_numbers(%{"numbers" => numbers}) when is_list(numbers), do: numbers
  defp baseline_numbers(_baseline), do: []

  defp decode_action_result(%AgentAction{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _result -> {:error, :invalid_retrospective_result}
    end
  end

  defp decode_action_result(_action), do: {:error, :invalid_retrospective_result}

  defp existing_suggestion_action(source, suggestion_index) do
    target_type = source.target_type
    target_id = source.target_id

    Repo.all(
      from action in AgentAction,
        where:
          action.action_key == "create_retrospective_issue" and
            action.target_type == ^target_type and action.target_id == ^target_id and
            action.state in ["queued", "running", "sync_pending", "done"]
    )
    |> Enum.find(fn action ->
      action.target_snapshot["source_action_id"] == source.id and
        action.target_snapshot["suggestion_index"] == suggestion_index
    end)
  end

  defp ensure_open(%Issue{state: "open"}), do: :ok
  defp ensure_open(%Issue{}), do: {:error, :issue_closed}
end
