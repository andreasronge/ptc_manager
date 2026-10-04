defmodule PtcManager.ExecutionArtifacts do
  @moduledoc "Seals provider-owned session files at managed run completion and teardown."
  import Ecto.Query
  require Logger
  alias PtcManager.Repo
  alias PtcManager.Operations.{AgentRun, Job, WorktreeAllocation}
  alias PtcManager.Repository.WorkerHelper

  def archive_job(job_id) when is_integer(job_id) do
    archive(where(AgentRun, [run], run.job_id == ^job_id))
  end

  def archive_job(_), do: :ok

  def archive_run(run_id), do: archive(where(AgentRun, [run], run.id == ^run_id))

  defp archive(query) do
    root = Application.get_env(:ptc_manager, :execution_artifact_root)

    if WorkerHelper.worker_boundary?() and is_binary(root) and root != "" do
      Repo.all(
        from run in query,
          join: job in Job,
          on: job.id == run.job_id,
          join: allocation in WorktreeAllocation,
          on: allocation.job_id == job.id,
          where: not is_nil(run.external_key),
          select: {run.id, job.id, job.repository_id, run.external_key, allocation.agent_kind}
      )
      |> Enum.each(fn {run_id, job_id, repository_id, key, kind} ->
        destination =
          Path.join([root, "repository-#{repository_id}", "job-#{job_id}", "agent-run-#{run_id}"])

        unless File.regular?(Path.join(destination, "manifest.json")) do
          session_id = key |> String.split(":") |> List.last()

          max_bytes =
            Application.get_env(:ptc_manager, :execution_artifact_max_bytes, 256_000_000)

          case WorkerHelper.run("/usr/local/bin/ptc-manager-worker-review", [
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
              Logger.warning(
                "Provider session archival failed for agent run #{run_id}; capture unavailable"
              )
          end
        end
      end)
    end

    :ok
  end
end
