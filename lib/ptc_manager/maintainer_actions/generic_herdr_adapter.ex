defmodule PtcManager.MaintainerActions.GenericHerdrAdapter do
  @moduledoc "Runs any configured ephemeral action through an explicitly selected Herdr kind."

  @behaviour PtcManager.MaintainerActions.Adapter

  alias PtcManager.AgentProfiles
  alias PtcManager.Automations
  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.InvestigationWorkspaces
  alias PtcManager.HealthSnapshotEvidence
  alias PtcManager.MaintainerActions.ActionAdapter, as: ResultValidator
  alias PtcManager.Operations
  alias PtcManager.Operations.AgentAction
  alias PtcManager.Repository.Checkout
  alias PtcManager.Repository.InvestigationWorkspace
  alias PtcManager.Repository.WorkerRepositoryTrust
  alias PtcManager.Repository.WorkerClaudeTrust
  alias PtcManager.Repository.WorkspaceSetup
  alias PtcManager.WorktreeSecurity
  alias PtcManager.Repository.WorkerAgentLogin
  alias PtcManager.Repository.WorkerCodexArming

  @command_grace_ms 5_000
  @prompt_stall_recovery_ms 30_000
  @prompt_stall_poll_ms 250

  @impl true
  def run(%AgentAction{automation_definition_version: version} = action)
      when not is_nil(version) do
    try do
      with :ok <- validate_health_snapshot(action),
           {:ok, profile} <- AgentProfiles.select(version.agent_selector),
           {:ok, output_path, schema_path} <- prepare_output(action),
           {:ok, path, workspace, pane} <- prepare_workspace(action),
           name = agent_name(action),
           {:ok, context} <-
             PtcManager.ManagedOperationContext.prepare_action(command(), pane, action),
           :ok <- remember_context(context),
           {:ok, agent_key} <- start_agent(name, pane, profile, path, action),
           dispatch = dispatch(action, profile.kind, name, workspace, pane, agent_key, path),
           {:ok, _run} <-
             Operations.attach_agent_action_herdr_run(action.id, action.attempt_count, dispatch),
           :ok <- Automations.record_invocation_runtime(action, profile.kind, name),
           :ok <- validate_health_snapshot_for_handoff(action),
           :ok <- ensure_prompt_delivery(name, action, output_path),
           {:ok, _output} <- prompt_and_wait(name, action, output_path, schema_path),
           :ok <- validate_health_snapshot(action),
           {:ok, result} <- read_result(output_path, action.action_key, action.target_snapshot) do
        {:ok, result}
      end
    after
      cleanup(action)
    end
  rescue
    error -> {:error, {:generic_herdr_failed, error.__struct__}}
  end

  def run(%AgentAction{}), do: {:error, :automation_version_missing}

  defp validate_health_snapshot(%AgentAction{
         action_key: "check_health",
         target_snapshot: %{"health_snapshot_evidence" => snapshot}
       }) do
    case HealthSnapshotEvidence.validate(snapshot) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, {:health_snapshot_unavailable, reason}}
    end
  end

  defp validate_health_snapshot(%AgentAction{action_key: "check_health"}),
    do: {:error, {:health_snapshot_unavailable, :health_snapshot_missing}}

  defp validate_health_snapshot(%AgentAction{}), do: :ok

  defp validate_health_snapshot_for_handoff(%AgentAction{
         action_key: "check_health",
         automation_definition_version: %{timeout_seconds: timeout_seconds},
         target_snapshot: %{"health_snapshot_evidence" => snapshot}
       }) do
    case HealthSnapshotEvidence.validate_for(snapshot, timeout_seconds) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, {:health_snapshot_unavailable, reason}}
    end
  end

  defp validate_health_snapshot_for_handoff(%AgentAction{action_key: "check_health"}),
    do: {:error, {:health_snapshot_unavailable, :health_snapshot_missing}}

  defp validate_health_snapshot_for_handoff(%AgentAction{}), do: :ok

  defp action_path(%AgentAction{target_snapshot: %{"source_path" => path}})
       when is_binary(path),
       do: {:ok, Path.expand(path)}

  defp action_path(%AgentAction{repository: repository}), do: Checkout.available_path(repository)

  defp prepare_workspace(
         %AgentAction{
           automation_definition_version: %{execution_profile: "ephemeral_investigation"}
         } = action
       ) do
    prepare_investigation_workspace(action)
  end

  defp prepare_workspace(action) do
    with {:ok, path} <- action_path(action),
         :ok <- trust_workspace(path),
         {:ok, workspace, pane} <- open_workspace(action, path) do
      {:ok, path, workspace, pane}
    end
  end

  defp prepare_investigation_workspace(action) do
    root = Application.get_env(:ptc_manager, :worktree_root)

    with {:ok, repository_path} <- Checkout.available_path(action.repository),
         true <- is_binary(root) and root != "",
         :ok <- WorktreeSecurity.validate_configured_root(root),
         {:ok, identity} <- InvestigationWorkspace.identity(action),
         path = InvestigationWorkspace.path(root, action.repository, action),
         {:ok, _run} <-
           Operations.prepare_agent_action_disposable_workspace(
             action.id,
             action.attempt_count,
             path,
             identity.branch
           ),
         {:ok, output} <-
           command().run([
             "worktree",
             "create",
             "--cwd",
             repository_path,
             "--branch",
             identity.branch,
             "--base",
             identity.source_sha,
             "--path",
             path,
             "--label",
             "review-issue-#{action.target_id}",
             "--no-focus"
           ]),
         {:ok, workspace, pane} <- remember_disposable_workspace(output, action),
         {:ok, report} <- setup_investigation(path, action) do
      Process.put({__MODULE__, :setup_report}, report)
      {:ok, path, workspace, pane}
    else
      false -> {:error, :worktree_root_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp remember_disposable_workspace(output, action) do
    case HerdrAdapter.decode_worktree(output) do
      {:ok, workspace, pane} = opened ->
        Process.put({__MODULE__, :workspace}, workspace)
        Process.put({__MODULE__, :disposable_workspace}, true)

        with {:ok, _run} <-
               Operations.attach_agent_action_disposable_workspace(
                 action.id,
                 action.attempt_count,
                 workspace,
                 pane,
                 Application.get_env(:ptc_manager, :herdr_session, "default")
               ) do
          opened
        end

      error ->
        error
    end
  end

  defp setup_investigation(path, action) do
    setup = Application.get_env(:ptc_manager, :workspace_setup, WorkspaceSetup)

    case PtcManager.Gateway.call(setup, :run, [path, action]) do
      {:ok, report} when is_map(report) ->
        with {:ok, _run} <-
               Operations.record_agent_action_workspace_setup(
                 action.id,
                 action.attempt_count,
                 report
               ) do
          {:ok, report}
        end

      {:error, report} when is_map(report) ->
        with {:ok, _run} <-
               Operations.record_agent_action_workspace_setup(
                 action.id,
                 action.attempt_count,
                 report
               ) do
          {:error, {:investigation_workspace_setup_failed, Map.get(report, :error)}}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_workspace_setup_result, other}}
    end
  end

  defp prepare_output(action) do
    directory =
      Application.get_env(:ptc_manager, :agent_action_output_dir) || System.tmp_dir!()

    with :ok <- File.mkdir_p(directory) do
      path = Path.join(directory, "ptc-result-action-#{action.id}-#{action.attempt_count}.json")
      schema_path = Path.rootname(path) <> ".schema.json"
      :ok = File.cp(result_schema(action.action_key), schema_path)
      :ok = File.chmod(schema_path, 0o440)
      Process.put({__MODULE__, :output_path}, path)
      Process.put({__MODULE__, :schema_path}, schema_path)
      {:ok, path, schema_path}
    end
  end

  defp open_workspace(action, path) do
    result =
      command().run([
        "worktree",
        "open",
        "--cwd",
        path,
        "--path",
        path,
        "--label",
        "automation-#{action.id}",
        "--no-focus"
      ])

    case result do
      {:ok, output} ->
        case HerdrAdapter.decode_worktree(output) do
          {:ok, workspace, _pane} = opened ->
            Process.put({__MODULE__, :workspace}, workspace)
            opened

          error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trust_workspace(path) do
    case WorkerRepositoryTrust.allow(path) do
      {:ok, :trusted} ->
        Process.put({__MODULE__, :trusted_path}, path)
        :ok

      {:ok, :not_required} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp start_agent(name, pane, profile, workspace_path, action) do
    with :ok <- WorkerAgentLogin.verify(profile.kind),
         :ok <- trust_agent_workspace(profile.kind, workspace_path),
         :ok <- WorkerCodexArming.prepare(profile.kind) do
      run_agent_start(name, pane, profile, workspace_path, action)
    end
  end

  defp trust_agent_workspace("claude", workspace_path) do
    case WorkerClaudeTrust.allow(workspace_path) do
      {:ok, :trusted} ->
        Process.put({__MODULE__, :claude_trusted_path}, workspace_path)
        :ok

      {:ok, :not_required} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp trust_agent_workspace(_kind, _workspace_path), do: :ok

  defp run_agent_start(name, pane, profile, workspace_path, action) do
    timeout = Application.get_env(:ptc_manager, :implementation_agent_start_timeout_ms, 120_000)

    agent_args =
      if action.automation_definition_version.execution_profile == "ephemeral_investigation" do
        HerdrAdapter.agent_arguments(profile.kind, workspace_path, [
          action.repository.local_path,
          workspace_path
        ])
      else
        AgentProfiles.expand_args(profile.args, workspace_path)
      end

    args =
      [
        "agent",
        "start",
        name,
        "--kind",
        profile.kind,
        "--pane",
        pane,
        "--timeout",
        Integer.to_string(timeout),
        "--"
      ] ++ agent_args

    case command().run(args, timeout + @command_grace_ms) do
      {:ok, output} -> {:ok, decode_agent_key(output, pane)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_and_wait(name, action, output_path, schema_path) do
    timeout = action.automation_definition_version.timeout_seconds * 1_000

    complete_prompt =
      action.prompt <>
        result_protocol(output_path, schema_path)

    with {:ok, prompt_path} <- write_prompt_file(action, complete_prompt) do
      submit_and_wait(name, prompt_loader(prompt_path), timeout)
    end
  end

  defp ensure_prompt_delivery(name, action, output_path) do
    marker_path = Path.rootname(output_path) <> ".ready"
    token = "ready-#{action.id}-#{action.attempt_count}"
    Process.put({__MODULE__, :ready_path}, marker_path)
    do_ensure_prompt_delivery(name, marker_path, token, 2)
  end

  defp do_ensure_prompt_delivery(_name, _marker_path, _token, 0),
    do: {:error, :agent_prompt_delivery_failed}

  defp do_ensure_prompt_delivery(name, marker_path, token, attempts_left) do
    prompt =
      "Initialization check only. Use the shell to write exactly #{token} followed by a newline to #{marker_path}.tmp, then rename it to #{marker_path}. Do not inspect the repository or access external services."

    result = submit_and_wait(name, prompt, 60_000)

    if ready_marker?(marker_path, token) do
      :ok
    else
      if attempts_left > 1 do
        do_ensure_prompt_delivery(name, marker_path, token, attempts_left - 1)
      else
        case result do
          {:error, _reason} = error -> error
          {:ok, _output} -> {:error, :agent_prompt_delivery_failed}
        end
      end
    end
  end

  defp ready_marker?(path, token) do
    case File.read(path) do
      {:ok, body} -> String.trim(body) == token
      {:error, _reason} -> false
    end
  end

  defp submit_and_wait(name, prompt, timeout) do
    result =
      command().run(
        [
          "agent",
          "prompt",
          name,
          prompt,
          "--wait",
          "--until",
          "working",
          "--until",
          "blocked",
          "--timeout",
          Integer.to_string(timeout)
        ],
        timeout + @command_grace_ms
      )

    case result do
      {:ok, _started} ->
        wait_for_completion(name, timeout)

      {:error, reason} = error ->
        case prompt_stalled_sequence(reason) do
          {:ok, sequence} -> recover_stalled_prompt(name, sequence, timeout, error)
          :error -> error
        end
    end
  end

  defp recover_stalled_prompt(name, baseline_sequence, timeout, original_error) do
    recovery_ms = min(timeout, @prompt_stall_recovery_ms)
    deadline = System.monotonic_time(:millisecond) + recovery_ms
    poll_prompt_state(name, baseline_sequence, timeout, deadline, original_error)
  end

  defp poll_prompt_state(name, baseline_sequence, timeout, deadline, original_error) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      original_error
    else
      result = command().run(["agent", "get", name], min(remaining, 2_000))

      case decode_agent_state(result) do
        {:ok, sequence, state} when sequence > baseline_sequence and state == "working" ->
          wait_for_completion(name, timeout)

        {:ok, sequence, state}
        when sequence > baseline_sequence and state in ["idle", "done", "blocked"] ->
          result

        _unchanged ->
          Process.sleep(min(remaining, @prompt_stall_poll_ms))
          poll_prompt_state(name, baseline_sequence, timeout, deadline, original_error)
      end
    end
  end

  defp decode_agent_state({:ok, output}) do
    with {:ok, decoded} <- Jason.decode(output),
         %{"state_change_seq" => sequence, "agent_status" => state}
         when is_integer(sequence) and is_binary(state) <- get_in(decoded, ["result", "agent"]) do
      {:ok, sequence, state}
    else
      _invalid -> :error
    end
  end

  defp decode_agent_state(_result), do: :error

  defp prompt_stalled_sequence({:herdr_exit, _status, output}) do
    with {:ok, %{"error" => %{"code" => "agent_prompt_stalled", "message" => message}}} <-
           Jason.decode(output),
         [sequence] <-
           Regex.run(~r/state_change_seq remained (\d+)/, message, capture: :all_but_first),
         {sequence, ""} <- Integer.parse(sequence) do
      {:ok, sequence}
    else
      _invalid -> :error
    end
  end

  defp prompt_stalled_sequence(_reason), do: :error

  defp wait_for_completion(name, timeout) do
    command().run(
      [
        "agent",
        "wait",
        name,
        "--until",
        "idle",
        "--until",
        "done",
        "--until",
        "blocked",
        "--timeout",
        Integer.to_string(timeout)
      ],
      timeout + @command_grace_ms
    )
  end

  defp write_prompt_file(action, prompt) do
    directory = Path.dirname(Process.get({__MODULE__, :output_path}))
    path = Path.join(directory, "ptc-prompt-action-#{action.id}-#{action.attempt_count}.txt")

    with :ok <- File.write(path, prompt),
         :ok <- File.chmod(path, 0o440) do
      Process.put({__MODULE__, :prompt_path}, path)
      {:ok, path}
    end
  end

  defp prompt_loader(path) do
    "Read and follow the complete task at #{path}. The file includes the required result protocol."
  end

  @doc false
  def result_protocol(output_path, schema_path)
      when is_binary(output_path) and is_binary(schema_path) do
    """

    Result protocol: read #{schema_path}, then atomically write one matching JSON object via #{output_path}.tmp to #{output_path}. Terminal output is not parsed.
    """
  end

  defp read_result(path, action_key, snapshot) do
    with {:ok, body} <- File.read(path),
         :ok <- require_result(body),
         {:ok, result} when is_map(result) <- Jason.decode(body),
         :ok <- ResultValidator.validate_result(result, action_key, snapshot) do
      {:ok, result}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_agent_result_json}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_agent_result}
    end
  end

  defp require_result(body) when is_binary(body) do
    if String.trim(body) == "", do: {:error, :agent_result_missing}, else: :ok
  end

  defp dispatch(action, kind, name, workspace, pane, agent_key, path) do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")

    %{
      workspace_id: workspace,
      pane_id: pane,
      session: session,
      external_key: "#{session}:#{agent_key}",
      agent_name: name,
      agent_kind: kind,
      worktree_path: path,
      worker_key: "herdr:#{session}",
      role: "manager",
      status_text: action_status(action)
    }
  end

  defp action_status(%AgentAction{
         automation_definition_version: %{execution_profile: "ephemeral_investigation"}
       }) do
    case Process.get({__MODULE__, :setup_report}) do
      %{cache_state: "hit"} ->
        "Reviewing the issue in a prepared disposable workspace (warm cache)."

      _report ->
        "Reviewing the issue in a prepared disposable workspace."
    end
  end

  defp action_status(action),
    do: "Running #{String.replace(action.action_key, "_", " ")} through Herdr."

  defp decode_agent_key(output, fallback) do
    with {:ok, decoded} <- Jason.decode(output),
         value when is_binary(value) <-
           get_in(decoded, ["result", "agent", "agent_session", "value"]) do
      value
    else
      _invalid -> fallback
    end
  end

  defp agent_name(action), do: "automation_a#{action.id}_f#{action.attempt_count}"

  defp cleanup(action) do
    if workspace = Process.delete({__MODULE__, :workspace}) do
      if Process.delete({__MODULE__, :disposable_workspace}) do
        remover = fn workspace_id ->
          ["worktree", "remove", "--workspace", workspace_id, "--force"]
          |> command().run()
          |> HerdrAdapter.action_workspace_removal_result()
        end

        recoverer = fn repository_path, path, label ->
          with {:ok, output} <-
                 command().run([
                   "worktree",
                   "open",
                   "--cwd",
                   repository_path,
                   "--path",
                   path,
                   "--label",
                   label,
                   "--no-focus"
                 ]),
               {:ok, workspace_id, _pane} <- HerdrAdapter.decode_worktree(output) do
            {:ok, workspace_id}
          end
        end

        _ = InvestigationWorkspaces.cleanup(action, remover, nil, workspace, recoverer)
      else
        _ = command().run(["workspace", "close", workspace])
      end
    end

    Process.delete({__MODULE__, :setup_report})

    if path = Process.delete({__MODULE__, :trusted_path}) do
      _ = WorkerRepositoryTrust.revoke(path)
    end

    if path = Process.delete({__MODULE__, :claude_trusted_path}) do
      _ = WorkerClaudeTrust.revoke(path)
    end

    if output = Process.delete({__MODULE__, :output_path}), do: File.rm(output)
    if schema = Process.delete({__MODULE__, :schema_path}), do: File.rm(schema)
    if prompt = Process.delete({__MODULE__, :prompt_path}), do: File.rm(prompt)
    if context = Process.delete({__MODULE__, :operation_context}), do: File.rm(context)

    if ready = Process.delete({__MODULE__, :ready_path}) do
      File.rm(ready)
      File.rm(ready <> ".tmp")
    end

    :ok
  end

  defp remember_context(%{path: path}) do
    Process.put({__MODULE__, :operation_context}, path)
    :ok
  end

  defp remember_context(nil), do: :ok

  defp result_schema("daily_digest"),
    do: Application.app_dir(:ptc_manager, "priv/codex/daily_digest_output.schema.json")

  defp result_schema(_action_key),
    do: Application.app_dir(:ptc_manager, "priv/codex/agent_action_output.schema.json")

  defp command,
    do: Application.get_env(:ptc_manager, :generic_herdr_command, PtcManager.Herdr.Command)
end
