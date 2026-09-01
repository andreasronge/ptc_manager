defmodule PtcManager.Dispatch do
  @moduledoc "Leases one approved job only after a synchronous GitHub freshness check."

  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.Clock
  alias PtcManager.Gateway
  alias PtcManager.Operations
  alias PtcManager.Worktrees

  def run_once(opts \\ []) do
    github = Keyword.get(opts, :github, Application.fetch_env!(:ptc_manager, :github_client))
    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:ptc_manager, :dispatch_adapter))
    worker_key = Keyword.get(opts, :worker_key, configured_worker_key())
    lease_ms = Keyword.get(opts, :lease_ms, configured_lease_ms())
    clock = Keyword.get(opts, :clock, PtcManager.Clock.System)

    Operations.expire_job_leases(
      Clock.utc_now(clock),
      Clock.utc_now(PtcManager.Clock.System)
    )

    case Operations.next_queued_job() do
      nil ->
        {:ok, :empty}

      job ->
        with {:ok, capacity} <- dispatch_capacity(worker_key, opts),
             :ok <- Worktrees.ensure_slot(worker_key, capacity, adapter) do
          dispatch_job(job, github, adapter, worker_key, lease_ms, capacity, clock)
        end
    end
  end

  defp dispatch_job(job, github, adapter, worker_key, lease_ms, capacity, clock) do
    with {:ok, remote} <- Gateway.call(github, :get_issue, [job.repository, job.issue.number]),
         {:ok, canonical} <- normalize_remote(remote, job.repository),
         {:ok, leased} <-
           Operations.lease_job(job.id, worker_key, canonical, lease_ms,
             capacity: capacity,
             now: Clock.utc_now(clock),
             lifecycle_now: Clock.utc_now(PtcManager.Clock.System)
           ) do
      context = %{
        job: leased,
        issue: leased.issue,
        repository: leased.repository
      }

      case Gateway.call(adapter, :dispatch, [context]) do
        {:ok, dispatch} ->
          dispatch = Map.put(dispatch, :lease_expires_at, leased.lease_expires_at)

          Operations.mark_job_working(
            leased.id,
            leased.fencing_token,
            worker_key,
            dispatch,
            Clock.utc_now(clock),
            Clock.utc_now(PtcManager.Clock.System)
          )

        {:error, {:safe, reason}} ->
          _ =
            Operations.mark_dispatch_failed(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason,
              Clock.utc_now(clock),
              Clock.utc_now(PtcManager.Clock.System)
            )

          {:error, reason}

        {:error, {:uncertain, reason}} ->
          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason,
              Clock.utc_now(clock),
              Clock.utc_now(PtcManager.Clock.System)
            )

          {:error, reason}

        {:error, reason} ->
          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason,
              Clock.utc_now(clock),
              Clock.utc_now(PtcManager.Clock.System)
            )

          {:error, reason}

        other ->
          reason = {:unexpected_dispatch_result, other}

          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              reason,
              Clock.utc_now(clock),
              Clock.utc_now(PtcManager.Clock.System)
            )

          {:error, reason}
      end
    end
  end

  defp normalize_remote(remote, repository) do
    {:ok, IssueSnapshot.normalize!(remote, repository)}
  rescue
    error -> {:error, {:invalid_github_issue, error.__struct__}}
  end

  defp configured_worker_key do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")
    "herdr:#{session}"
  end

  defp configured_lease_ms,
    do: Application.get_env(:ptc_manager, :dispatch_lease_ms, 1_800_000)

  defp dispatch_capacity(worker_key, opts) do
    case Keyword.fetch(opts, :capacity) do
      {:ok, capacity} when is_integer(capacity) and capacity > 0 -> {:ok, capacity}
      {:ok, _capacity} -> {:error, :invalid_agent_capacity}
      :error -> Operations.dispatch_capacity(worker_key)
    end
  end
end
