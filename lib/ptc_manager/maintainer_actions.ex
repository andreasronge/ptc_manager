defmodule PtcManager.MaintainerActions do
  @moduledoc "Queues and executes named maintainer prompts while GitHub remains canonical."

  import Ecto.Query, only: [from: 2]

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.Sync, as: ActionSync
  alias PtcManager.Manager
  alias PtcManager.MergeDecisions
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, Issue, PrPublication}
  alias PtcManager.Repo

  def enabled?, do: Application.get_env(:ptc_manager, :agent_actions_enabled, false)

  def enqueue(action_key, issue_id, actor)
      when action_key in ["prepare_issue", "review_issue"] and
             is_integer(issue_id) and is_binary(actor) do
    with %Issue{} = issue <- Issue |> Repo.get(issue_id) |> Repo.preload(:repository),
         :ok <- ensure_open(issue),
         {:ok, attrs} <- Catalog.build(action_key, %{issue: issue, repository: issue.repository}) do
      Operations.enqueue_agent_action(Map.merge(attrs, %{action_key: action_key, actor: actor}))
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(action_key, publication_id, actor)
      when action_key in ["pr_retrospective", "prepare_merge_decision", "repair_pr"] and
             is_integer(publication_id) and is_binary(actor) do
    with %PrPublication{} = publication <-
           PrPublication
           |> Repo.get(publication_id)
           |> Repo.preload([:repository, job: [:issue, :repository, :worktree_allocation]]),
         repository when not is_nil(repository) <- publication_repository(publication),
         {:ok, attrs} <-
           Catalog.build(action_key, %{
             publication: publication,
             issue: publication.job && publication.job.issue,
             repository: repository
           }) do
      Operations.enqueue_agent_action(
        Map.merge(attrs, %{
          action_key: action_key,
          actor: actor
        })
      )
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(_action_key, _target_id, _actor), do: {:error, :unknown_agent_action}

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
      Operations.enqueue_agent_action(
        Map.merge(attrs, %{
          action_key: "create_retrospective_issue",
          actor: actor
        })
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

  def run_once(opts \\ []) do
    adapter =
      Keyword.get(
        opts,
        :adapter,
        Application.fetch_env!(:ptc_manager, :agent_action_adapter)
      )

    sync = Keyword.get(opts, :sync, ActionSync)
    Operations.expire_agent_action_attempts()

    case Operations.next_agent_action_sync_pending() do
      nil -> execute_next(adapter, sync)
      action -> reconcile_action(action, sync)
    end
  end

  defp execute_next(adapter, sync) do
    case Operations.next_agent_action_candidate() do
      nil ->
        {:ok, :empty}

      candidate ->
        with {:ok, prepared} <- prepare_for_execution(candidate, sync),
             {:ok, {action, token}} <- Operations.claim_agent_action(prepared.id) do
          result = adapter.run(action)
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
        else
          {:deferred, action} -> {:ok, action}
          {:terminal, action} -> {:ok, action}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp prepare_for_execution(%{action_key: action_key} = action, sync)
       when action_key in ["pr_retrospective", "create_retrospective_issue"] do
    case sync.sync_action(action) do
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

  defp prepare_for_execution(%{action_key: "prepare_merge_decision"} = action, sync) do
    publication = Repo.get!(PrPublication, action.target_id)

    if PrPublication.external?(publication) do
      fail_preflight(action.id, :external_pull_request_has_no_isolated_merge_reviewer)
    else
      case sync.sync_action(action) do
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

  defp prepare_for_execution(%{action_key: "repair_pr"} = action, sync) do
    case sync.sync_action(action) do
      {:ok, %{pull_request: status}} ->
        if repair_needed?(status) do
          with {:ok, prompt} <- refreshed_repair_prompt(action, status),
               {:ok, prepared} <-
                 Operations.record_agent_action_target_snapshot(
                   action.id,
                   MergeDecisions.snapshot(status),
                   prompt
                 ) do
            case reserve_repair_worktree(action) do
              {:ok, _allocation} ->
                {:ok, prepared}

              {:error, :dispatch_capacity} ->
                case Operations.defer_agent_action_preflight(action.id, :dispatch_capacity) do
                  {:ok, deferred} -> {:deferred, deferred}
                  {:error, defer_reason} -> {:error, defer_reason}
                end

              {:error, reason} ->
                fail_preflight(action.id, reason)
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

  defp prepare_for_execution(action, _sync), do: {:ok, action}

  defp repair_needed?(status) do
    status.checks_state == "failure" or status.mergeability == "conflicting"
  end

  defp settle_repair_result(
         %{action_key: "repair_pr", target_snapshot: snapshot},
         {:error, _reason},
         %{pull_request: %{head_sha: head_sha}}
       )
       when is_map(snapshot) do
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

  defp refreshed_repair_prompt(action, status) do
    publication =
      PrPublication
      |> Repo.get!(action.target_id)
      |> Repo.preload([:repository, job: [:issue, :repository]])

    if PrPublication.external?(publication) do
      repository = publication.repository
      {:ok, Catalog.external_repair_prompt(repository, publication, status)}
    else
      {:ok, nil}
    end
  end

  defp reserve_repair_worktree(action) do
    publication = Repo.get!(PrPublication, action.target_id)

    if PrPublication.external?(publication),
      do: {:ok, :external_workspace_created_by_adapter},
      else: Operations.reserve_worktree_for_repair(publication.job_id, "repair-agent")
  end

  defp publication_repository(%PrPublication{repository: %{} = repository}), do: repository

  defp publication_repository(%PrPublication{job: %{repository: %{} = repository}}),
    do: repository

  defp publication_repository(_publication), do: nil

  defp fail_preflight(action_id, reason) do
    case Operations.fail_agent_action_preflight(action_id, reason) do
      {:ok, failed} -> {:terminal, failed}
      {:error, failure} -> {:error, failure}
    end
  end

  defp sync_after_execution(sync, action, result) do
    if is_atom(sync) and Code.ensure_loaded?(sync) and function_exported?(sync, :sync_action, 2),
      do: sync.sync_action(action, result),
      else: sync.sync_action(action)
  end

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
         %{action_key: action_key, target_id: issue_id},
         {:ok, result},
         _summary
       )
       when action_key in ["prepare_issue", "review_issue"] do
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
         {:ok, _proposal} <- Manager.store_analysis(issue, analysis) do
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
