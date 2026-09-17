defmodule PtcManager.Repository.WorkspaceSetup do
  @moduledoc "Runs one repository-owned setup script before an agent gets a writable worktree."

  alias PtcManager.CommandEnvironment
  alias PtcManager.Operations.{AgentAction, Job}
  alias PtcManager.Repository.{Contract, GitProbe}

  @type report :: %{
          state: binary(),
          script: binary() | nil,
          source_sha: binary() | nil,
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          duration_ms: non_neg_integer(),
          exit_status: non_neg_integer() | nil,
          output: binary(),
          output_truncated: boolean(),
          cache_state: binary() | nil,
          phase_durations: %{optional(binary()) => non_neg_integer()},
          error: term() | nil
        }

  @callback run(binary(), struct()) :: {:ok, report()} | {:error, report()}

  def run(path, %Job{} = job), do: run(path, job, [])
  def run(path, %AgentAction{} = action), do: run(path, action, [])

  @doc false
  def run(path, owner, opts)
      when is_binary(path) and is_list(opts) and
             (is_struct(owner, Job) or is_struct(owner, AgentAction)) do
    runner = Keyword.get(opts, :runner, PtcManager.Repository.WorkspaceSetup.Runner)
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, branch, source_sha} <- workspace_identity(path, owner),
           :ok <- GitProbe.reclaimable(path, branch, source_sha),
           {:ok, contract} <- Contract.for_workspace(path, source_sha),
           {:ok, script} <- Contract.bootstrap_script(contract),
           :ok <- GitProbe.tracked_executable(path, source_sha, script),
           execution <-
             run_setup(runner, path, script, contract.bootstrap_timeout_minutes * 60_000, owner),
           {:ok, output, truncated} <- successful_execution(execution, script, source_sha),
           :ok <- GitProbe.reclaimable(path, branch, source_sha) do
        {:ok, script, source_sha, 0, output, truncated}
      else
        {:error, {:workspace_setup_exit, status, output, truncated, script, source_sha}} ->
          {:error, script, source_sha, status, output, truncated, :workspace_setup_failed}

        {:error, {:workspace_setup_runner, reason, script, source_sha}} ->
          {:error, script, source_sha, nil, "", false, reason}

        {:error, reason} ->
          {:error, nil, current_head(path, owner), nil, "", false, reason}
      end

    ended_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    duration_ms = max(System.monotonic_time(:millisecond) - started, 0)

    case result do
      {:ok, script, source_sha, exit_status, output, truncated} ->
        {:ok,
         report(
           "passed",
           script,
           source_sha,
           started_at,
           ended_at,
           duration_ms,
           exit_status,
           output,
           truncated,
           nil
         )}

      {:error, script, source_sha, exit_status, output, truncated, reason} ->
        {:error,
         report(
           "failed",
           script,
           source_sha,
           started_at,
           ended_at,
           duration_ms,
           exit_status,
           output,
           truncated,
           reason
         )}
    end
  end

  defp run_setup(runner, path, script, timeout, owner) do
    if function_exported?(runner, :run, 4),
      do: runner.run(path, script, timeout, setup_artifact(owner)),
      else: runner.run(path, script, timeout)
  end

  defp setup_artifact(owner) do
    case Application.get_env(:ptc_manager, :execution_artifact_root) do
      root when is_binary(root) and root != "" ->
        {type, attempt} =
          if is_struct(owner, Job),
            do: {"job", owner.fencing_token},
            else: {"action", owner.attempt_count}

        Path.join([
          root,
          "repository-#{owner.repository_id}",
          "#{type}-#{owner.id}",
          "workspace-setup-#{attempt}"
        ])

      _ ->
        nil
    end
  end

  defp successful_execution({:ok, %{exit_status: 0, output: output} = result}, _script, _sha),
    do: {:ok, output, Map.get(result, :output_truncated, false)}

  defp successful_execution({:ok, %{exit_status: status, output: output} = result}, script, sha),
    do:
      {:error,
       {:workspace_setup_exit, status, output, Map.get(result, :output_truncated, false), script,
        sha}}

  defp successful_execution({:error, reason}, script, sha),
    do: {:error, {:workspace_setup_runner, reason, script, sha}}

  defp successful_execution(_other, script, sha),
    do: {:error, {:workspace_setup_runner, :invalid_workspace_setup_result, script, sha}}

  defp current_head(path, owner) do
    case workspace_head(path, owner) do
      {:ok, sha} -> sha
      _error -> nil
    end
  end

  defp workspace_identity(path, %Job{branch_name: branch} = job) do
    with {:ok, source_sha} <- GitProbe.current_job_head(path, job) do
      {:ok, branch, source_sha}
    end
  end

  defp workspace_identity(path, %AgentAction{} = action) do
    with {:ok, identity} <-
           PtcManager.Repository.InvestigationWorkspace.identity(action),
         {:ok, source_sha} <- GitProbe.current_investigation_head(path, action) do
      {:ok, identity.branch, source_sha}
    end
  end

  defp workspace_head(path, %Job{} = job), do: GitProbe.current_job_head(path, job)

  defp workspace_head(path, %AgentAction{} = action),
    do: GitProbe.current_investigation_head(path, action)

  defp report(
         state,
         script,
         source_sha,
         started_at,
         ended_at,
         duration_ms,
         exit_status,
         output,
         truncated,
         error
       ) do
    metrics = setup_metrics(output)

    %{
      state: state,
      script: script,
      source_sha: source_sha,
      started_at: started_at,
      ended_at: ended_at,
      duration_ms: duration_ms,
      exit_status: exit_status,
      output: output,
      output_truncated: truncated,
      cache_state: metrics.cache_state,
      phase_durations: metrics.phase_durations,
      error: error
    }
  end

  defp setup_metrics(output) when is_binary(output) do
    Enum.reduce(String.split(output, "\n"), %{cache_state: nil, phase_durations: %{}}, fn
      "PTC_SETUP_METRIC cache_state=" <> state, metrics
      when state in ["hit", "miss", "disabled"] ->
        %{metrics | cache_state: state}

      "PTC_SETUP_METRIC " <> metric, metrics ->
        case String.split(metric, "=", parts: 2) do
          [name, value] -> put_phase_duration(metrics, name, value)
          _invalid -> metrics
        end

      _line, metrics ->
        metrics
    end)
  end

  defp put_phase_duration(metrics, name, value) do
    allowed = ~w(cache_restore_ms dependencies_ms asset_tools_ms cache_publish_ms)

    with true <- name in allowed,
         {duration, ""} <- Integer.parse(value),
         true <- duration >= 0 and duration <= 3_600_000 do
      put_in(metrics, [:phase_durations, name], duration)
    else
      _invalid -> metrics
    end
  end

  defmodule Runner do
    @moduledoc false

    @output_limit 65_536

    def run(path, script, timeout_ms), do: run(path, script, timeout_ms, nil)

    def run(path, script, timeout_ms, artifact_directory) do
      absolute_script = Path.join(path, script)
      started = System.monotonic_time(:millisecond)

      {command, args} =
        command(
          path,
          script,
          absolute_script,
          Application.get_env(:ptc_manager, :herdr_run_as_user),
          Application.get_env(
            :ptc_manager,
            :workspace_bootstrap_wrapper,
            "/usr/local/bin/ptc-manager-worker-bootstrap"
          )
        )

      port =
        Port.open(
          {:spawn_executable, command},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args,
            cd: path,
            env: normalize_environment(CommandEnvironment.scrub())
          ]
        )

      artifact = open_artifact(artifact_directory)

      result =
        receive_result(
          port,
          "",
          false,
          started,
          started + timeout_ms,
          script,
          artifact
        )

      seal_artifact(artifact, result)
      result
    rescue
      error -> {:error, {:workspace_setup_unavailable, error.__struct__}}
    end

    defp receive_result(port, output, truncated, started, deadline, script, artifact) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, data}} ->
          artifact = write_artifact(artifact, data)
          {output, truncated} = append_bounded(output, data, truncated)
          receive_result(port, output, truncated, started, deadline, script, artifact)

        {^port, {:exit_status, status}} ->
          {:ok,
           %{
             exit_status: status,
             output: output,
             output_truncated: truncated,
             duration_ms: max(System.monotonic_time(:millisecond) - started, 0),
             script: script
           }}
      after
        remaining ->
          if artifact do
            Process.put({__MODULE__, artifact.path}, %{artifact | coverage: "partial"})
          end

          close_port(port)
          {:error, :workspace_setup_timeout}
      end
    end

    defp open_artifact(nil), do: nil

    defp open_artifact(directory) do
      try do
        ensure_shared_directory!(directory)
        path = Path.join(directory, "combined.log")

        artifact = %{
          io: File.open!(path, [:write, :binary, :exclusive]),
          path: path,
          bytes: 0,
          coverage: "complete"
        }

        Process.put({__MODULE__, path}, artifact)
        artifact
      rescue
        _ -> nil
      end
    end

    defp ensure_shared_directory!(directory) do
      case Application.get_env(:ptc_manager, :execution_artifact_root) do
        root when is_binary(root) and root != "" ->
          root = Path.expand(root)
          relative = Path.relative_to(Path.expand(directory), root)

          Enum.reduce(Path.split(relative), root, fn part, parent ->
            path = Path.join(parent, part)

            case File.lstat(path) do
              {:error, :enoent} ->
                File.mkdir!(path)
                File.chmod!(path, 0o2770)

              {:ok, %{type: :directory, mode: mode}} ->
                if Bitwise.band(mode, 0o020) == 0,
                  do:
                    raise(File.Error,
                      reason: :eacces,
                      action: "use shared artifact directory",
                      path: path
                    )

              _ ->
                raise File.Error,
                  reason: :eacces,
                  action: "use shared artifact directory",
                  path: path
            end

            path
          end)

        _ ->
          File.mkdir_p!(directory)
      end

      :ok
    end

    defp write_artifact(nil, _data), do: nil

    defp write_artifact(%{io: nil} = artifact, _data), do: artifact

    defp write_artifact(artifact, data) do
      limit = Application.get_env(:ptc_manager, :execution_artifact_max_bytes, 256_000_000)

      updated =
        if artifact.bytes + byte_size(data) <= limit do
          case IO.binwrite(artifact.io, data) do
            :ok -> %{artifact | bytes: artifact.bytes + byte_size(data)}
            _ -> %{artifact | coverage: "error"}
          end
        else
          %{artifact | coverage: "partial"}
        end

      Process.put({__MODULE__, artifact.path}, updated)
      updated
    end

    defp seal_artifact(nil, _result), do: :ok

    defp seal_artifact(artifact, result) do
      artifact = Process.delete({__MODULE__, artifact.path}) || artifact
      File.close(artifact.io)
      bytes = File.stat!(artifact.path).size

      digest =
        artifact.path
        |> File.stream!(65_536, [])
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      status =
        case result do
          {:ok, %{exit_status: value}} -> value
          _ -> nil
        end

      manifest = %{
        schema_version: 1,
        kind: "workspace_setup",
        coverage: artifact.coverage,
        exit_status: status,
        streams: %{
          combined: %{
            path: "combined.log",
            bytes: bytes,
            sha256: digest,
            coverage: artifact.coverage
          }
        }
      }

      File.write!(
        Path.join(Path.dirname(artifact.path), "manifest.json"),
        Jason.encode!(manifest),
        [:exclusive]
      )

      :ok
    rescue
      _ -> :ok
    end

    @doc false
    def command(path, script, _absolute_script, user, wrapper)
        when is_binary(user) and user != "" do
      {"/usr/bin/sudo", ["-n", "-H", "-u", user, "--", wrapper, path, script]}
    end

    def command(_path, _script, absolute_script, _user, _wrapper), do: {absolute_script, []}

    defp append_bounded(output, data, truncated) do
      output = output <> String.replace_invalid(data)

      if byte_size(output) <= @output_limit do
        {output, truncated}
      else
        {binary_part(output, byte_size(output) - @output_limit, @output_limit), true}
      end
    end

    defp normalize_environment(environment) do
      Enum.map(environment, fn
        {key, nil} -> {to_charlist(key), false}
        {key, value} -> {to_charlist(key), to_charlist(value)}
      end)
    end

    defp close_port(port) do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
