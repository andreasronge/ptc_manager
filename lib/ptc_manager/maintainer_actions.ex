defmodule PtcManager.MaintainerActions do
  @moduledoc "Queues and executes named maintainer prompts while GitHub remains canonical."

  import Ecto.Query, only: [from: 2]

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.Sync, as: ActionSync
  alias PtcManager.Manager
  alias PtcManager.MergeDecisions
  alias PtcManager.Operations
  alias PtcManager.Operations.{Issue, PrPublication}
  alias PtcManager.Repo

  def enabled?, do: Application.get_env(:ptc_manager, :agent_actions_enabled, false)

  def enqueue("prepare_issue" = action_key, issue_id, actor)
      when is_integer(issue_id) and is_binary(actor) do
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
      when action_key in ["pr_retrospective", "prepare_merge_decision"] and
             is_integer(publication_id) and is_binary(actor) do
    with %PrPublication{} = publication <-
           PrPublication
           |> Repo.get(publication_id)
           |> Repo.preload(job: [:issue, :repository]),
         {:ok, attrs} <-
           Catalog.build(action_key, %{
             publication: publication,
             issue: publication.job.issue,
             repository: publication.job.repository
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
          sync_result = sync.sync_action(action)

          case sync_result do
            {:ok, summary} ->
              Operations.complete_agent_action(
                action.id,
                token,
                store_private_analysis(action, result, summary)
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

  defp prepare_for_execution(%{action_key: "pr_retrospective"} = action, sync) do
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
    case sync.sync_action(action) do
      {:ok, %{pull_request: status}} ->
        Operations.record_agent_action_target_snapshot(action.id, MergeDecisions.snapshot(status))

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

  defp prepare_for_execution(action, _sync), do: {:ok, action}

  defp reconcile_action(action, sync) do
    case sync.sync_action(action) do
      {:ok, summary} = synced ->
        case store_private_analysis(action, stored_execution_result(action), summary) do
          {:ok, _result} ->
            Operations.complete_agent_action_sync(action.id, synced)

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
         %{action_key: "prepare_issue", target_id: issue_id},
         {:ok, result},
         _summary
       ) do
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

    case canonical_retrospective_matches(
           publication,
           repository_id,
           result["outcome"],
           result["created_issue_numbers"],
           baseline_numbers(baseline_issue_numbers)
         ) do
      :ok -> {:ok, result}
      {:error, reason} -> {:error, {:retrospective_validation_failed, reason}}
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

  defp ensure_open(%Issue{state: "open"}), do: :ok
  defp ensure_open(%Issue{}), do: {:error, :issue_closed}
end
