defmodule PtcManager.Dispatch do
  @moduledoc "Leases one approved job only after a synchronous GitHub freshness check."

  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.Operations

  def run_once(opts \\ []) do
    github = Keyword.get(opts, :github, Application.fetch_env!(:ptc_manager, :github_client))
    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:ptc_manager, :dispatch_adapter))
    worker_key = Keyword.get(opts, :worker_key, configured_worker_key())
    lease_ms = Keyword.get(opts, :lease_ms, configured_lease_ms())

    Operations.expire_job_leases()

    case Operations.next_queued_job() do
      nil ->
        {:ok, :empty}

      job ->
        dispatch_job(job, github, adapter, worker_key, lease_ms)
    end
  end

  defp dispatch_job(job, github, adapter, worker_key, lease_ms) do
    with {:ok, remote} <- github.get_issue(job.repository, job.issue.number),
         {:ok, canonical} <- normalize_remote(remote, job.repository.id),
         {:ok, leased} <- Operations.lease_job(job.id, worker_key, canonical, lease_ms) do
      context = %{
        job: leased,
        issue: leased.issue,
        repository: leased.repository
      }

      case adapter.dispatch(context) do
        {:ok, dispatch} ->
          dispatch = Map.put(dispatch, :lease_expires_at, leased.lease_expires_at)
          Operations.mark_job_working(leased.id, leased.fencing_token, worker_key, dispatch)

        {:error, {:safe, reason}} ->
          _ = Operations.mark_dispatch_failed(leased.id, leased.fencing_token, worker_key, reason)
          {:error, reason}

        {:error, {:uncertain, reason}} ->
          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason
            )

          {:error, reason}

        {:error, reason} ->
          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason
            )

          {:error, reason}

        other ->
          reason = {:unexpected_dispatch_result, other}

          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason
            )

          {:error, reason}
      end
    end
  end

  defp normalize_remote(remote, repository_id) do
    {:ok, IssueSnapshot.normalize!(remote, repository_id)}
  rescue
    error -> {:error, {:invalid_github_issue, error.__struct__}}
  end

  defp configured_worker_key do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")
    "herdr:#{session}"
  end

  defp configured_lease_ms,
    do: Application.get_env(:ptc_manager, :dispatch_lease_ms, 1_800_000)
end
