defmodule PtcManager.MaintainerActions.CodexAdapter do
  @moduledoc "Runs an authorized maintainer action through ephemeral Codex and authenticated gh."

  @behaviour PtcManager.MaintainerActions.Adapter

  alias PtcManager.Manager.CodexAdapter, as: PrivateCodexAdapter
  alias PtcManager.Operations.AgentAction

  @impl true
  def run(%AgentAction{repository: repository} = action) do
    with {:ok, path} <- repository_path(repository) do
      run_codex(action, path)
    end
  end

  defp run_codex(action, repository_path) do
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

    args = [
      "exec",
      "--ephemeral",
      "--ignore-user-config",
      "--dangerously-bypass-approvals-and-sandbox",
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
            Application.get_env(:ptc_manager, :agent_action_run_as_user)
          )

        System.cmd(command, command_args,
          env: PrivateCodexAdapter.command_environment(),
          stderr_to_stdout: true
        )
      end)

    try do
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_output, 0}} -> decode_output(output_path, action.action_key)
        {:ok, {output, status}} -> {:error, {:codex_exit, status, bounded(output)}}
        nil -> {:error, :codex_timeout}
      end
    after
      File.rm(output_path)
    end
  rescue
    error -> {:error, {:codex_command_failed, error.__struct__}}
  end

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
  def validate_result(
        %{
          "outcome" => outcome,
          "private_summary" => summary,
          "why_it_matters" => why_it_matters,
          "scope" => scope,
          "risk" => risk,
          "technical_evidence" => technical_evidence,
          "github_changes" => changes,
          "evidence" => evidence,
          "created_issue_numbers" => created_issue_numbers
        },
        action_key
      )
      when outcome in [
             "ready",
             "blocked",
             "needs-decision",
             "reject",
             "followups-created",
             "no-followups",
             "merge-ready",
             "merge-blocked",
             "merge-needs-decision"
           ] and is_binary(summary) and is_binary(why_it_matters) and
             scope in ["small", "medium", "large"] and risk in ["low", "medium", "high"] and
             is_binary(technical_evidence) and is_list(changes) and is_list(evidence),
      do: validate_action_result(action_key, outcome, created_issue_numbers, changes)

  def validate_result(_result, _action_key), do: {:error, :invalid_agent_action_output}

  defp validate_outcome("prepare_issue", outcome)
       when outcome in ["ready", "blocked", "needs-decision", "reject"],
       do: :ok

  defp validate_outcome("pr_retrospective", outcome)
       when outcome in ["followups-created", "no-followups"],
       do: :ok

  defp validate_outcome("prepare_merge_decision", outcome)
       when outcome in ["merge-ready", "merge-blocked", "merge-needs-decision"],
       do: :ok

  defp validate_outcome(_action_key, _outcome), do: {:error, :invalid_agent_action_outcome}

  defp validate_action_result(action_key, outcome, created_issue_numbers, changes) do
    with :ok <- validate_outcome(action_key, outcome),
         :ok <- validate_created_issue_numbers(action_key, outcome, created_issue_numbers),
         :ok <- validate_github_changes(action_key, changes) do
      :ok
    end
  end

  defp validate_github_changes("prepare_merge_decision", []), do: :ok

  defp validate_github_changes("prepare_merge_decision", _changes),
    do: {:error, :unexpected_github_changes}

  defp validate_github_changes(_action_key, _changes), do: :ok

  defp validate_created_issue_numbers("prepare_issue", _outcome, []), do: :ok
  defp validate_created_issue_numbers("prepare_merge_decision", _outcome, []), do: :ok
  defp validate_created_issue_numbers("pr_retrospective", "no-followups", []), do: :ok

  defp validate_created_issue_numbers(
         "pr_retrospective",
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

  defp schema_path,
    do: Application.app_dir(:ptc_manager, "priv/codex/agent_action_output.schema.json")

  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)
end
