defmodule PtcManager.MaintainerActions.CodexAdapter do
  @moduledoc "Runs maintainer actions through Codex or a retained Herdr implementation session."

  @behaviour PtcManager.MaintainerActions.Adapter

  alias PtcManager.MaintainerActions.{ExternalPrRepairAdapter, RetainedHerdrAdapter}
  alias PtcManager.IssueDecision
  alias PtcManager.Manager.CodexAdapter, as: PrivateCodexAdapter
  alias PtcManager.Operations.{AgentAction, PrPublication}
  alias PtcManager.Repo
  alias PtcManager.Repository.SourceSnapshot

  @impl true
  def run(%AgentAction{action_key: action_key} = action)
      when action_key in ["repair_pr", "repair_and_merge_pr"] do
    publication = Repo.get!(PrPublication, action.target_id)

    default_adapter =
      if PrPublication.external?(publication),
        do: ExternalPrRepairAdapter,
        else: RetainedHerdrAdapter

    adapter = Application.get_env(:ptc_manager, :repair_agent_adapter, default_adapter)
    adapter.run(action)
  end

  def run(%AgentAction{repository: repository} = action) do
    with {:ok, path} <- repository_path(action, repository) do
      run_codex(action, path, [])
    end
  end

  defp run_codex(action, repository_path, opts) do
    output_directory =
      Application.get_env(:ptc_manager, :agent_action_output_dir) ||
        Application.get_env(:ptc_manager, :manager_output_dir) || System.tmp_dir!()

    File.mkdir_p!(output_directory)

    output_path =
      Path.join(
        output_directory,
        "ptc-agent-action-#{action.id}-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(output_path, "")
    File.chmod!(output_path, 0o660)

    binary = Application.get_env(:ptc_manager, :codex_binary, "codex")
    timeout = Application.get_env(:ptc_manager, :agent_action_timeout_ms, 1_800_000)

    isolation_args =
      if Keyword.get(opts, :sandboxed, false),
        do: ["--sandbox", "workspace-write", "--approve-for-me"],
        else: ["--dangerously-bypass-approvals-and-sandbox"]

    args =
      [
        "exec",
        "--ephemeral",
        "--ignore-user-config"
      ] ++
        isolation_args ++
        [
          "--output-schema",
          schema_path(),
          "--output-last-message",
          output_path,
          "-C",
          repository_path,
          action.prompt
        ]

    task =
      Task.async(fn ->
        {command, command_args} =
          PrivateCodexAdapter.codex_command(
            binary,
            args,
            Keyword.get(
              opts,
              :run_as_user,
              Application.get_env(:ptc_manager, :agent_action_run_as_user)
            )
          )

        environment =
          PrivateCodexAdapter.command_environment()
          |> Map.new()
          |> Map.merge(%{
            "GIT_CONFIG_COUNT" => "1",
            "GIT_CONFIG_KEY_0" => "safe.directory",
            "GIT_CONFIG_VALUE_0" => repository_path,
            "GIT_OPTIONAL_LOCKS" => "0"
          })
          |> Map.to_list()

        System.cmd(command, command_args,
          env: environment,
          stderr_to_stdout: true
        )
      end)

    try do
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_output, 0}} -> decode_output(output_path, action.action_key)
        {:ok, {output, status}} -> {:error, PrivateCodexAdapter.codex_exit_error(status, output)}
        nil -> {:error, :codex_timeout}
      end
    after
      File.rm(output_path)
    end
  rescue
    error -> {:error, {:codex_command_failed, error.__struct__}}
  end

  @doc false
  def run_at(%AgentAction{} = action, repository_path) when is_binary(repository_path) do
    run_at(action, repository_path, [])
  end

  @doc false
  def run_at(%AgentAction{} = action, repository_path, opts) when is_binary(repository_path) do
    if File.dir?(repository_path),
      do: run_codex(action, Path.expand(repository_path), opts),
      else: {:error, :repository_path_unavailable}
  end

  defp repository_path(
         %AgentAction{action_key: "repair_pr", target_id: publication_id},
         _repository
       ) do
    publication =
      PrPublication
      |> Repo.get(publication_id)
      |> Repo.preload(job: :worktree_allocation)

    case publication && publication.job.worktree_allocation do
      %{path: path} when is_binary(path) ->
        if File.dir?(path),
          do: {:ok, Path.expand(path)},
          else: {:error, :repair_worktree_unavailable}

      _allocation ->
        {:error, :repair_worktree_unavailable}
    end
  end

  defp repository_path(
         %AgentAction{
           action_key: action_key,
           target_snapshot: %{"source_path" => path, "source_sha" => source_sha}
         },
         repository
       )
       when action_key in ["prepare_issue", "review_issue", "resolve_issue_decision"] and
              is_binary(path) and is_binary(source_sha) do
    case SourceSnapshot.verify(repository, path, source_sha) do
      :ok -> {:ok, Path.expand(path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp repository_path(_action, repository), do: repository_path(repository)

  defp repository_path(repository) do
    path = Application.get_env(:ptc_manager, :repository_path) || repository.local_path

    if is_binary(path) and File.dir?(path),
      do: {:ok, path},
      else: {:error, :repository_path_unavailable}
  end

  defp decode_output(path, action_key) do
    with {:ok, body} <- File.read(path),
         {:ok, result} <- Jason.decode(body),
         :ok <- validate_result(result, action_key) do
      {:ok, result}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_codex_json}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def validate_result(result, action_key) when is_map(result) do
    result
    |> Map.put_new("suggestions", [])
    |> Map.put_new("decision_question", "")
    |> Map.put_new("decision_options", [])
    |> validate_normalized_result(action_key)
  end

  def validate_result(_result, _action_key), do: {:error, :invalid_agent_action_output}

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
              "followups-proposed",
              "followups-created",
              "no-followups",
              "merge-ready",
              "merge-blocked",
              "merge-needs-decision",
              "repaired",
              "repair-blocked"
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
       when outcome in ["ready", "blocked", "needs-decision", "reject"],
       do: :ok

  defp validate_outcome("review_issue", outcome)
       when outcome in ["ready", "blocked", "needs-decision", "reject"],
       do: :ok

  defp validate_outcome("resolve_issue_decision", outcome)
       when outcome in ["ready", "blocked", "needs-decision", "reject"],
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
       when action_key in ["prepare_issue", "review_issue", "resolve_issue_decision"] do
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

  defp validate_github_changes(_action_key, _changes), do: :ok

  defp validate_created_issue_numbers("prepare_issue", _outcome, []), do: :ok
  defp validate_created_issue_numbers("review_issue", _outcome, []), do: :ok
  defp validate_created_issue_numbers("resolve_issue_decision", _outcome, []), do: :ok
  defp validate_created_issue_numbers("prepare_merge_decision", _outcome, []), do: :ok
  defp validate_created_issue_numbers("repair_pr", _outcome, []), do: :ok
  defp validate_created_issue_numbers("pr_retrospective", "followups-proposed", []), do: :ok
  defp validate_created_issue_numbers("pr_retrospective", "no-followups", []), do: :ok
  defp validate_created_issue_numbers("create_retrospective_issue", "no-followups", []), do: :ok

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

  defp schema_path,
    do: Application.app_dir(:ptc_manager, "priv/codex/agent_action_output.schema.json")
end
