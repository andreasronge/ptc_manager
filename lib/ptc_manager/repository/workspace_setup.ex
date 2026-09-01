defmodule PtcManager.Repository.WorkspaceSetup do
  @moduledoc "Runs one repository-owned setup script before an implementation agent starts."

  alias PtcManager.Manager.CodexAdapter, as: PrivateCodexAdapter
  alias PtcManager.Operations.Job
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
          error: term() | nil
        }

  @callback run(binary(), struct()) :: {:ok, report()} | {:error, report()}

  def run(path, %Job{} = job), do: run(path, job, [])

  @doc false
  def run(path, %Job{} = job, opts) when is_binary(path) and is_list(opts) do
    runner = Keyword.get(opts, :runner, PtcManager.Repository.WorkspaceSetup.Runner)
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, source_sha} <- GitProbe.current_job_head(path, job),
           :ok <- GitProbe.reclaimable(path, job.branch_name, source_sha),
           {:ok, contract} <- Contract.for_workspace(path, source_sha),
           {:ok, script} <- Contract.bootstrap_script(contract),
           :ok <- GitProbe.tracked_executable(path, source_sha, script),
           execution <- runner.run(path, script, contract.bootstrap_timeout_minutes * 60_000),
           {:ok, output, truncated} <- successful_execution(execution, script, source_sha),
           :ok <- GitProbe.reclaimable(path, job.branch_name, source_sha) do
        {:ok, script, source_sha, 0, output, truncated}
      else
        {:error, {:workspace_setup_exit, status, output, truncated, script, source_sha}} ->
          {:error, script, source_sha, status, output, truncated, :workspace_setup_failed}

        {:error, {:workspace_setup_runner, reason, script, source_sha}} ->
          {:error, script, source_sha, nil, "", false, reason}

        {:error, reason} ->
          {:error, nil, current_head(path, job), nil, "", false, reason}
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

  defp current_head(path, job) do
    case GitProbe.current_job_head(path, job) do
      {:ok, sha} -> sha
      _error -> nil
    end
  end

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
      error: error
    }
  end

  defmodule Runner do
    @moduledoc false

    @output_limit 65_536

    def run(path, script, timeout_ms) do
      source_sha = git!(path, ["rev-parse", "HEAD"])
      absolute_script = Path.join(path, script)
      started = System.monotonic_time(:millisecond)
      {command, args} = command(absolute_script)

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
            env: normalize_environment(PrivateCodexAdapter.command_environment())
          ]
        )

      receive_result(
        port,
        "",
        false,
        started,
        started + timeout_ms,
        script,
        source_sha
      )
    rescue
      error -> {:error, {:workspace_setup_unavailable, error.__struct__}}
    end

    defp receive_result(port, output, truncated, started, deadline, script, source_sha) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, data}} ->
          {output, truncated} = append_bounded(output, data, truncated)
          receive_result(port, output, truncated, started, deadline, script, source_sha)

        {^port, {:exit_status, status}} ->
          {:ok,
           %{
             exit_status: status,
             output: output,
             output_truncated: truncated,
             duration_ms: max(System.monotonic_time(:millisecond) - started, 0),
             script: script,
             source_sha: source_sha
           }}
      after
        remaining ->
          close_port(port)
          {:error, :workspace_setup_timeout}
      end
    end

    defp command(script) do
      case Application.get_env(:ptc_manager, :herdr_run_as_user) do
        user when is_binary(user) and user != "" ->
          {"/usr/bin/sudo", ["-n", "-H", "-u", user, "--", script]}

        _user ->
          {script, []}
      end
    end

    defp git!(path, args) do
      {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
      String.trim(output)
    end

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
