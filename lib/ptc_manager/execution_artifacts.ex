defmodule PtcManager.ExecutionArtifacts do
  @moduledoc "Seals exact provider sessions after confirmed managed workspace shutdown."
  import Ecto.Query
  require Logger
  alias PtcManager.Repo
  alias PtcManager.Operations.{AgentAction, AgentRun, Job, WorktreeAllocation}
  alias PtcManager.Automations.Invocation
  alias PtcManager.Repository.WorkerHelper

  def archive_job(job_id) when is_integer(job_id),
    do: archive(where(AgentRun, [run], run.job_id == ^job_id))

  def archive_job(_), do: :ok
  def archive_run(run_id), do: archive(where(AgentRun, [run], run.id == ^run_id))

  def session_token(session_id),
    do: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)

  def sessions(run, fallback_kind \\ "unknown") do
    remembered = run.provider_sessions || %{}

    case run.external_key do
      key when is_binary(key) ->
        Map.put_new(
          remembered,
          key |> String.split(":") |> List.last(),
          fallback_kind || "unknown"
        )

      _ ->
        remembered
    end
  end

  def archive_action(action, kind, session_id) do
    if enabled?() do
      run =
        Repo.one(
          from r in AgentRun,
            where: r.agent_action_id == ^action.id and r.fencing_token == ^action.attempt_count,
            order_by: [desc: r.id],
            limit: 1
        )

      label = if run, do: "agent-run-#{run.id}", else: "attempt-#{action.attempt_count}"
      capture(action.repository_id, "action-#{action.id}", label, kind, session_id)
    else
      :ok
    end
  end

  def close_action_runs(action) do
    if enabled?() do
      Repo.all(
        from r in AgentRun,
          where:
            r.agent_action_id == ^action.id and is_nil(r.disposable_cleanup_state) and
              not is_nil(r.external_key)
      )
      |> Enum.reduce_while(:ok, fn run, :ok ->
        if is_binary(run.herdr_workspace) do
          command =
            Application.get_env(:ptc_manager, :generic_herdr_command, PtcManager.Herdr.Command)

          case command.run(["workspace", "close", run.herdr_workspace])
               |> PtcManager.Dispatch.HerdrAdapter.action_workspace_removal_result() do
            :ok ->
              case archive_run(run.id) do
                :ok -> {:cont, :ok}
                {:error, _} = error -> {:halt, error}
              end

            {:error, _} = error ->
              {:halt, error}
          end
        else
          {:cont, :ok}
        end
      end)
    else
      :ok
    end
  end

  defp archive(query) do
    if enabled?() do
      Repo.all(
        from run in query,
          left_join: job in Job,
          on: job.id == run.job_id,
          left_join: allocation in WorktreeAllocation,
          on: allocation.job_id == job.id,
          left_join: action in AgentAction,
          on: action.id == run.agent_action_id,
          left_join: invocation in Invocation,
          on: invocation.agent_action_id == action.id,
          select:
            {run, job.repository_id, action.repository_id, allocation.agent_kind,
             invocation.selected_agent_kind}
      )
      |> Enum.reduce_while(:ok, fn {run, job_repository, action_repository, job_kind, action_kind},
                                   :ok ->
        owner = if run.job_id, do: "job-#{run.job_id}", else: "action-#{run.agent_action_id}"

        result =
          Enum.reduce_while(sessions(run, job_kind || action_kind), :ok, fn {session, kind},
                                                                            :ok ->
            result =
              capture(
                job_repository || action_repository,
                owner,
                "agent-run-#{run.id}",
                kind,
                session
              )

            case result do
              :ok -> {:cont, :ok}
              {:error, _} = error -> {:halt, error}
            end
          end)

        case result do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp capture(repository_id, owner, label, kind, session_id) do
    if enabled?() do
      root = Application.fetch_env!(:ptc_manager, :execution_artifact_root)

      destination =
        Path.join([
          root,
          "repository-#{repository_id}",
          owner,
          "#{label}-#{session_token(session_id)}"
        ])

      max_bytes = Application.get_env(:ptc_manager, :execution_artifact_max_bytes, 256_000_000)
      command = Application.get_env(:ptc_manager, :execution_artifact_command) || WorkerHelper

      if File.regular?(Path.join(destination, "manifest.json")) do
        :ok
      else
        case command.run("/usr/local/bin/ptc-manager-worker-review", [
               "archive-session",
               kind,
               session_id,
               destination,
               Integer.to_string(max_bytes),
               root
             ]) do
          {_, 0} ->
            :ok

          _ ->
            Logger.warning("Provider session archival failed for #{label}; cleanup will retry")
            {:error, :provider_session_archival_failed}
        end
      end
    else
      :ok
    end
  end

  defp enabled? do
    root = Application.get_env(:ptc_manager, :execution_artifact_root)
    is_binary(root) and root != ""
  end
end
