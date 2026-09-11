defmodule PtcManager.MaintainerActions.ActionAdapter do
  @moduledoc "Routes maintainer actions to Herdr and validates their structured results."

  @behaviour PtcManager.MaintainerActions.Adapter

  alias PtcManager.MaintainerActions.{FreshWorktreeRepairAdapter, RetainedHerdrAdapter}
  alias PtcManager.IssueDecision
  alias PtcManager.Operations.{AgentAction, PrPublication}
  alias PtcManager.Repo
  alias PtcManager.MaintainerActions.GenericHerdrAdapter

  @repair_action_keys ~w(repair_pr repair_and_merge_pr)

  @impl true
  def run(%AgentAction{action_key: "daily_digest"} = action),
    do: GenericHerdrAdapter.run(action)

  def run(%AgentAction{action_key: action_key} = action)
      when action_key in @repair_action_keys,
      do: action |> repair_adapter() |> then(& &1.run(action))

  def run(
        %AgentAction{
          automation_definition_version: %{
            execution_profile: profile
          }
        } = action
      )
      when profile in ["generic_ephemeral", "ephemeral_investigation"] do
    GenericHerdrAdapter.run(action)
  end

  def run(%AgentAction{}), do: {:error, :unsupported_agent_action_profile}

  @impl true
  def ensure_ready(%AgentAction{action_key: action_key} = action)
      when action_key in @repair_action_keys do
    adapter = Application.get_env(:ptc_manager, :repair_agent_adapter, RetainedHerdrAdapter)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :ensure_ready, 1),
      do: adapter.ensure_ready(action),
      else: :ok
  end

  def ensure_ready(%AgentAction{}), do: :ok

  # Preflight recorded which worktree this repair runs in, so routing follows that
  # decision rather than deriving its own and risking a different answer.
  defp repair_adapter(%AgentAction{} = action) do
    Application.get_env(:ptc_manager, :repair_agent_adapter, default_repair_adapter(action))
  end

  defp default_repair_adapter(%AgentAction{target_snapshot: %{"repair_mode" => "fresh"}}),
    do: FreshWorktreeRepairAdapter

  defp default_repair_adapter(%AgentAction{target_snapshot: %{"repair_mode" => "retained"}}),
    do: RetainedHerdrAdapter

  # Actions recorded before repair mode existed keep the routing they ran under.
  defp default_repair_adapter(%AgentAction{target_id: publication_id}) do
    if PrPublication.external?(Repo.get!(PrPublication, publication_id)),
      do: FreshWorktreeRepairAdapter,
      else: RetainedHerdrAdapter
  end

  @doc false
  def validate_result(result, "daily_digest") when is_map(result) do
    validate_daily_digest_result(result)
  end

  def validate_result(result, action_key) when is_map(result) do
    result
    |> Map.put_new("suggestions", [])
    |> Map.put_new("decision_question", "")
    |> Map.put_new("decision_options", [])
    |> validate_normalized_result(action_key)
  end

  def validate_result(_result, _action_key), do: {:error, :invalid_agent_action_output}

  @doc """
  Validates a result against the outcomes this particular action may return.

  Some actions are queued with a narrower set than their key allows, because
  their whole input came from a model. Saying so in the prompt is not a
  restriction — the prompt is what the model reads, and this is where
  deterministic code decides — so the permitted set is persisted on the action
  and enforced here.
  """
  def validate_result(result, action_key, %{"allowed_outcomes" => allowed})
      when is_map(result) and is_list(allowed) and allowed != [] do
    with :ok <- validate_result(result, action_key) do
      if Map.get(result, "outcome") in allowed,
        do: :ok,
        else: {:error, :outcome_not_permitted_for_action}
    end
  end

  def validate_result(result, action_key, _snapshot), do: validate_result(result, action_key)

  defp validate_daily_digest_result(%{
         "status" => status,
         "title" => title,
         "summary" => summary,
         "markdown" => markdown,
         "window_started_at" => window_started_at,
         "window_ended_at" => window_ended_at,
         "source_head_sha" => source_head_sha,
         "change_count" => change_count,
         "pull_request_numbers" => pull_request_numbers
       })
       when status in ["published", "no-changes"] and is_binary(title) and
              is_binary(summary) and is_binary(markdown) and is_binary(window_started_at) and
              is_binary(window_ended_at) and is_binary(source_head_sha) and
              is_integer(change_count) and change_count in 0..100 and
              is_list(pull_request_numbers) do
    valid_strings? =
      String.trim(title) != "" and byte_size(title) <= 180 and
        String.trim(summary) != "" and byte_size(summary) <= 4_000 and
        String.trim(markdown) != "" and byte_size(markdown) <= 40_000

    valid_window? = valid_iso8601?(window_started_at) and valid_iso8601?(window_ended_at)
    valid_sha? = Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, source_head_sha)

    valid_prs? =
      Enum.all?(pull_request_numbers, &(is_integer(&1) and &1 > 0)) and
        pull_request_numbers == Enum.sort(Enum.uniq(pull_request_numbers)) and
        length(pull_request_numbers) <= 100

    status_matches? =
      (status == "published" and change_count > 0) or
        (status == "no-changes" and change_count == 0 and pull_request_numbers == [])

    if valid_strings? and valid_window? and valid_sha? and valid_prs? and status_matches?,
      do: :ok,
      else: {:error, :invalid_daily_digest_output}
  end

  defp validate_daily_digest_result(_result), do: {:error, :invalid_daily_digest_output}

  defp valid_iso8601?(value) do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp validate_normalized_result(
         %{
           "outcome" => outcome,
           "private_summary" => summary,
           "why_it_matters" => why_it_matters,
           "scope" => scope,
           "risk" => risk,
           "technical_evidence" => technical_evidence,
           "github_changes" => changes,
           "evidence" => evidence,
           "decision_question" => decision_question,
           "decision_options" => decision_options,
           "created_issue_numbers" => created_issue_numbers,
           "suggestions" => suggestions
         },
         action_key
       )
       when outcome in [
              "ready",
              "blocked",
              "needs-decision",
              "reject",
              "split",
              "structured",
              "followups-proposed",
              "followups-created",
              "no-followups",
              "merge-ready",
              "merge-blocked",
              "merge-needs-decision",
              "repaired",
              "repair-blocked",
              "completed",
              "no-changes",
              "needs_information",
              "needs_breakdown",
              "outdated",
              "duplicate"
            ] and is_binary(summary) and is_binary(why_it_matters) and
              scope in ["small", "medium", "large"] and risk in ["low", "medium", "high"] and
              is_binary(technical_evidence) and is_list(changes) and is_list(evidence) and
              is_binary(decision_question) and is_list(decision_options) and is_list(suggestions),
       do:
         validate_action_result(
           action_key,
           outcome,
           created_issue_numbers,
           changes,
           suggestions,
           decision_question,
           decision_options
         )

  defp validate_normalized_result(_result, _action_key),
    do: {:error, :invalid_agent_action_output}

  defp validate_outcome("prepare_issue", outcome)
       when outcome in ["ready", "blocked", "needs-decision", "reject", "split"],
       do: :ok

  defp validate_outcome("structure_collection", outcome)
       when outcome in ["structured", "no-changes", "needs-decision"],
       do: :ok

  defp validate_outcome("collection_handoff", outcome)
       when outcome in ["completed", "no-changes", "needs-decision"],
       do: :ok

  defp validate_outcome("collection_closeout", outcome)
       when outcome in ["completed", "no-changes", "needs-decision"],
       do: :ok

  # An escalation may only ask; see Catalog's allowed outcomes for the reason.
  defp validate_outcome("report_collection_blocker", "needs-decision"), do: :ok

  defp validate_outcome("merge_reviewed_pr", outcome)
       when outcome in ["repaired", "repair-blocked"],
       do: :ok

  # This action may only report a blocker. It cannot mark an issue ready or
  # close it, whatever the model-written evidence it was given asks for.
  defp validate_outcome("report_issue_blocker", outcome)
       when outcome in ["blocked", "needs-decision"],
       do: :ok

  defp validate_outcome("review_issue", outcome)
       when outcome in ["ready", "blocked", "needs-decision", "reject", "split"],
       do: :ok

  # The generic completed/no-changes fallback below must not widen the
  # collection actions past the outcomes their prompts state.
  defp validate_outcome(action_key, _outcome)
       when action_key in [
              "structure_collection",
              "collection_handoff",
              "collection_closeout",
              "report_collection_blocker",
              "merge_reviewed_pr"
            ],
       do: {:error, :invalid_agent_action_outcome}

  defp validate_outcome("resolve_issue_decision", outcome)
       when outcome in ["ready", "blocked", "needs-decision", "reject"],
       do: :ok

  defp validate_outcome("private_issue_analysis", outcome)
       when outcome in [
              "ready",
              "needs_information",
              "needs_breakdown",
              "outdated",
              "duplicate"
            ],
       do: :ok

  defp validate_outcome("pr_retrospective", outcome)
       when outcome in ["followups-proposed", "no-followups"],
       do: :ok

  defp validate_outcome("create_retrospective_issue", outcome)
       when outcome in ["followups-created", "no-followups"],
       do: :ok

  defp validate_outcome("prepare_merge_decision", outcome)
       when outcome in ["merge-ready", "merge-blocked", "merge-needs-decision"],
       do: :ok

  defp validate_outcome(action_key, outcome)
       when action_key in ["repair_pr", "repair_and_merge_pr"] and
              outcome in ["repaired", "repair-blocked"],
       do: :ok

  defp validate_outcome(_action_key, outcome) when outcome in ["completed", "no-changes"],
    do: :ok

  defp validate_outcome(_action_key, _outcome), do: {:error, :invalid_agent_action_outcome}

  defp validate_action_result(
         action_key,
         outcome,
         created_issue_numbers,
         changes,
         suggestions,
         decision_question,
         decision_options
       ) do
    with :ok <- validate_outcome(action_key, outcome),
         :ok <- validate_created_issue_numbers(action_key, outcome, created_issue_numbers),
         :ok <- validate_github_changes(action_key, changes),
         :ok <- validate_suggestions(action_key, outcome, suggestions),
         :ok <- validate_decision(action_key, outcome, decision_question, decision_options) do
      :ok
    end
  end

  defp validate_decision(action_key, "needs-decision", question, options)
       when action_key in [
              "prepare_issue",
              "report_issue_blocker",
              "review_issue",
              "resolve_issue_decision",
              "structure_collection",
              "collection_handoff",
              "collection_closeout",
              "report_collection_blocker"
            ] do
    case IssueDecision.from_result(%{
           "outcome" => "needs-decision",
           "decision_question" => question,
           "decision_options" => options
         }) do
      {:ok, _decision} -> :ok
      {:error, _reason} -> {:error, :invalid_issue_decision}
    end
  end

  defp validate_decision(_action_key, _outcome, "", []), do: :ok

  defp validate_decision(_action_key, _outcome, _question, _options),
    do: {:error, :unexpected_issue_decision}

  defp validate_github_changes("prepare_merge_decision", []), do: :ok

  defp validate_github_changes("prepare_merge_decision", _changes),
    do: {:error, :unexpected_github_changes}

  defp validate_github_changes("pr_retrospective", []), do: :ok

  defp validate_github_changes("pr_retrospective", _changes),
    do: {:error, :unexpected_github_changes}

  defp validate_github_changes("private_issue_analysis", []), do: :ok

  defp validate_github_changes("private_issue_analysis", _changes),
    do: {:error, :unexpected_github_changes}

  defp validate_github_changes(_action_key, _changes), do: :ok

  defp validate_created_issue_numbers("private_issue_analysis", _outcome, []), do: :ok

  defp validate_created_issue_numbers("prepare_issue", "split", numbers),
    do: issue_numbers(numbers)

  defp validate_created_issue_numbers("prepare_issue", _outcome, []), do: :ok
  defp validate_created_issue_numbers("report_issue_blocker", _outcome, []), do: :ok

  defp validate_created_issue_numbers("review_issue", "split", numbers),
    do: issue_numbers(numbers)

  defp validate_created_issue_numbers("review_issue", _outcome, []), do: :ok
  defp validate_created_issue_numbers("resolve_issue_decision", _outcome, []), do: :ok
  defp validate_created_issue_numbers("prepare_merge_decision", _outcome, []), do: :ok
  defp validate_created_issue_numbers("repair_pr", _outcome, []), do: :ok
  defp validate_created_issue_numbers("merge_reviewed_pr", _outcome, []), do: :ok
  defp validate_created_issue_numbers("report_collection_blocker", _outcome, []), do: :ok

  # Structuring may only create issues while it reports a structure; a handoff
  # or close-out only while it reports work done.
  defp validate_created_issue_numbers("structure_collection", "structured", numbers),
    do: issue_numbers(numbers)

  defp validate_created_issue_numbers("structure_collection", _outcome, []), do: :ok

  defp validate_created_issue_numbers("collection_handoff", "completed", numbers),
    do: issue_numbers(numbers)

  defp validate_created_issue_numbers("collection_handoff", _outcome, []), do: :ok

  defp validate_created_issue_numbers("collection_closeout", "completed", [_ | _] = numbers),
    do: issue_numbers(numbers)

  defp validate_created_issue_numbers("collection_closeout", outcome, [])
       when outcome in ["no-changes", "needs-decision"],
       do: :ok

  defp validate_created_issue_numbers(action_key, _outcome, _numbers)
       when action_key in ["structure_collection", "collection_handoff", "collection_closeout"],
       do: {:error, :invalid_created_issue_numbers}

  defp validate_created_issue_numbers("pr_retrospective", "followups-proposed", []), do: :ok
  defp validate_created_issue_numbers("pr_retrospective", "no-followups", []), do: :ok
  defp validate_created_issue_numbers("create_retrospective_issue", "no-followups", []), do: :ok

  defp validate_created_issue_numbers(_action_key, outcome, issue_numbers)
       when outcome in ["completed", "no-changes"] and is_list(issue_numbers),
       do: issue_numbers(issue_numbers)

  defp validate_created_issue_numbers(
         "create_retrospective_issue",
         "followups-created",
         issue_numbers
       )
       when is_list(issue_numbers) and issue_numbers != [] do
    if Enum.all?(issue_numbers, &(is_integer(&1) and &1 > 0)) and
         Enum.uniq(issue_numbers) == issue_numbers,
       do: :ok,
       else: {:error, :invalid_created_issue_numbers}
  end

  defp validate_created_issue_numbers(_action_key, _outcome, _issue_numbers),
    do: {:error, :invalid_created_issue_numbers}

  defp issue_numbers(numbers) when is_list(numbers) do
    if Enum.all?(numbers, &(is_integer(&1) and &1 > 0)) and Enum.uniq(numbers) == numbers,
      do: :ok,
      else: {:error, :invalid_created_issue_numbers}
  end

  defp issue_numbers(_numbers), do: {:error, :invalid_created_issue_numbers}

  defp validate_suggestions("pr_retrospective", "followups-proposed", suggestions)
       when suggestions != [] do
    if Enum.all?(suggestions, &valid_suggestion?/1),
      do: :ok,
      else: {:error, :invalid_retrospective_suggestions}
  end

  defp validate_suggestions("pr_retrospective", "no-followups", []), do: :ok
  defp validate_suggestions(_action_key, _outcome, []), do: :ok

  defp validate_suggestions(_action_key, _outcome, _suggestions),
    do: {:error, :unexpected_retrospective_suggestions}

  defp valid_suggestion?(%{
         "title" => title,
         "simple_summary" => summary,
         "why_it_matters" => why,
         "category" => category,
         "technical_evidence" => evidence,
         "suggested_issue_body" => body
       }) do
    Enum.all?([title, summary, why, evidence, body], &(is_binary(&1) and String.trim(&1) != "")) and
      category in [
        "potential-bug",
        "refactoring",
        "flaky-test",
        "missing-test",
        "surprise",
        "other"
      ]
  end

  defp valid_suggestion?(_suggestion), do: false
end
