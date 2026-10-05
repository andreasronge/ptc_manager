defmodule PtcManager.Repository.WorkspaceSetup do
  @moduledoc """
  Runs a repository's configured setup command before an agent gets a writable
  worktree.

  The command and its timeout are repository settings, not repository content,
  so a repository needs no checked-in script. It runs as the worker in the new
  worktree with the repository's agent environment variables.
  """

  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.CommandEnvironment
  alias PtcManager.Operations.{AgentAction, Job, Repository}
  alias PtcManager.Repository.GitProbe

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
           {:ok, setup} <- configured_setup(owner, opts),
           script = setup.command,
           execution <-
             runner.run(
               path,
               script,
               setup.timeout_minutes * 60_000,
               setup.environment,
               setup_artifact(owner)
             ),
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

  # Tests pass the setup directly; production reads the repository's setting.
  defp configured_setup(owner, opts) do
    case Keyword.fetch(opts, :setup) do
      {:ok, setup} -> {:ok, Map.put_new(setup, :environment, [])}
      :error -> repository_setup(owner.repository_id)
    end
  end

  defp repository_setup(repository_id) do
    case PtcManager.Repo.get(Repository, repository_id) do
      %Repository{workspace_setup_command: command, workspace_setup_timeout_minutes: timeout}
      when is_binary(command) and is_integer(timeout) ->
        {:ok,
         %{
           command: command,
           timeout_minutes: timeout,
           environment: AgentEnvironmentVariables.list(repository_id)
         }}

      _unconfigured ->
        {:error, :workspace_setup_not_configured}
    end
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

    def run(path, command, timeout_ms, variables \\ [], artifact_directory \\ nil) do
      started = System.monotonic_time(:millisecond)
      user = Application.get_env(:ptc_manager, :herdr_run_as_user)

      wrapper =
        Application.get_env(
          :ptc_manager,
          :workspace_bootstrap_wrapper,
          "/usr/local/bin/ptc-manager-worker-bootstrap"
        )

      # Across OS identities the variables reach the worker through a file only
      # it and the coordinator can read; sudo passes no environment.
      with {:ok, environment_file} <- environment_file(user, variables) do
        try do
          {executable, args} = command(path, command, user, wrapper, environment_file)
          environment = if environment_file, do: [], else: variables

          port =
            Port.open(
              {:spawn_executable, executable},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                :hide,
                args: args,
                cd: path,
                env: normalize_environment(CommandEnvironment.scrub(), environment)
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
              command,
              artifact
            )

          seal_artifact(artifact, result)
          result
        after
          if environment_file, do: File.rm(environment_file)
        end
      end
    rescue
      error -> {:error, {:workspace_setup_unavailable, error.__struct__}}
    end

    defp environment_file(user, variables)
         when is_binary(user) and user != "" and variables != [],
         do: PtcManager.ManagedOperationContext.write_setup_environment(variables)

    defp environment_file(_user, _variables), do: {:ok, nil}

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
      sync_result = :file.sync(artifact.io)
      close_result = File.close(artifact.io)

      coverage =
        if sync_result == :ok and close_result == :ok, do: artifact.coverage, else: "error"

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
        coverage: coverage,
        diagnostic:
          if(coverage == "error", do: "workspace capture write or finalization failed", else: nil),
        exit_status: status,
        streams: %{
          combined: %{
            path: "combined.log",
            bytes: bytes,
            sha256: digest,
            coverage: coverage
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
      _ ->
        require Logger
        Logger.warning("Workspace capture finalization failed; output may be incomplete")

        File.write(
          Path.join(Path.dirname(artifact.path), "manifest.json"),
          Jason.encode!(%{
            schema_version: 1,
            kind: "workspace_setup",
            coverage: "error",
            diagnostic: "workspace capture finalization failed",
            streams: %{}
          })
        )

        :ok
    end

    @doc false
    def command(path, command, user, wrapper, environment_file)
        when is_binary(user) and user != "" do
      {"/usr/bin/sudo",
       ["-n", "-H", "-u", user, "--", wrapper, path, command] ++ List.wrap(environment_file)}
    end

    def command(_path, command, _user, _wrapper, _environment_file),
      do: {"/bin/sh", ["-c", command]}

    defp append_bounded(output, data, truncated) do
      output = output <> String.replace_invalid(data)

      if byte_size(output) <= @output_limit do
        {output, truncated}
      else
        {binary_part(output, byte_size(output) - @output_limit, @output_limit), true}
      end
    end

    defp normalize_environment(environment, variables) do
      Enum.map(environment, fn
        {key, nil} -> {to_charlist(key), false}
        {key, value} -> {to_charlist(key), to_charlist(value)}
      end) ++
        Enum.map(variables, &{to_charlist(&1.name), to_charlist(&1.value)})
    end

    defp close_port(port) do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end
end
