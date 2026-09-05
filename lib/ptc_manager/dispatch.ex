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

    source_updater =
      Keyword.get(opts, :source_updater, Application.fetch_env!(:ptc_manager, :source_updater))

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
          dispatch_job(
            job,
            github,
            source_updater,
            adapter,
            worker_key,
            lease_ms,
            capacity,
            clock
          )
        end
    end
  end

  defp dispatch_job(job, github, source_updater, adapter, worker_key, lease_ms, capacity, clock) do
    lease_now = Clock.utc_now(clock)
    lifecycle_now = Clock.utc_now(PtcManager.Clock.System)

    with {:ok, remote} <- Gateway.call(github, :get_issue, [job.repository, job.issue.number]),
         {:ok, canonical} <- normalize_remote(remote, job.repository),
         {:ok, source} <- Gateway.call(source_updater, :refresh, [job.repository]),
         {:ok, leased} <-
           Operations.lease_job(job.id, worker_key, canonical, lease_ms,
             capacity: capacity,
             now: lease_now,
             lifecycle_now: lifecycle_now
           ) do
      context = %{
        job: leased,
        issue: leased.issue,
        repository: leased.repository,
        source: source
      }

      adapter_result = Gateway.call(adapter, :dispatch, [context])
      acknowledgement_lease_now = Clock.utc_now(clock)
      acknowledgement_lifecycle_now = Clock.utc_now(PtcManager.Clock.System)

      with :ok <-
             record_workspace_setup(
               leased,
               worker_key,
               adapter_result,
               acknowledgement_lease_now,
               acknowledgement_lifecycle_now
             ) do
        handle_dispatch_result(
          adapter_result,
          leased,
          worker_key,
          acknowledgement_lease_now,
          acknowledgement_lifecycle_now
        )
      else
        {:error, reason} ->
          _ =
            Operations.mark_dispatch_uncertain(
              leased.id,
              leased.fencing_token,
              worker_key,
              {:workspace_setup_evidence_failed, reason},
              acknowledgement_lease_now,
              acknowledgement_lifecycle_now
            )

          {:error, reason}
      end
    end
  end

  defp handle_dispatch_result(
         adapter_result,
         leased,
         worker_key,
         lease_now,
         lifecycle_now
       ) do
    case adapter_result do
      {:ok, dispatch} ->
        dispatch = Map.put(dispatch, :lease_expires_at, leased.lease_expires_at)

        Operations.mark_job_working(
          leased.id,
          leased.fencing_token,
          worker_key,
          dispatch,
          lease_now,
          lifecycle_now
        )

      {:error, {:safe, {:worktree_create_failed, message}}} when is_binary(message) ->
        _ =
          Operations.mark_dispatch_failed(
            leased.id,
            leased.fencing_token,
            worker_key,
            "Herdr could not create the job worktree: #{message}",
            lease_now,
            lifecycle_now
          )

        {:error, {:worktree_create_failed, message}}

      {:error, {:safe, {:workspace_setup_failed, report}}} ->
        reason = Map.get(report, :error) || :workspace_setup_failed

        _ =
          Operations.mark_dispatch_failed(
            leased.id,
            leased.fencing_token,
            worker_key,
            reason,
            lease_now,
            lifecycle_now
          )

        {:error, reason}

      {:error, {:safe, reason}} ->
        _ =
          Operations.mark_dispatch_failed(
            leased.id,
            leased.fencing_token,
            worker_key,
            reason,
            lease_now,
            lifecycle_now
          )

        {:error, reason}

      {:error, {:uncertain, reason}} ->
        _ =
          Operations.mark_dispatch_uncertain(
            leased.id,
            leased.fencing_token,
            worker_key,
            reason,
            lease_now,
            lifecycle_now
          )

        {:error, reason}

      {:error, reason} ->
        _ =
          Operations.mark_dispatch_uncertain(
            leased.id,
            leased.fencing_token,
            worker_key,
            reason,
            lease_now,
            lifecycle_now
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
            lease_now,
            lifecycle_now
          )

        {:error, reason}
    end
  end

  defp record_workspace_setup(
         leased,
         worker_key,
         adapter_result,
         lease_now,
         lifecycle_now
       ) do
    case workspace_setup_report(adapter_result) do
      nil ->
        :ok

      report ->
        case Operations.record_workspace_setup(
               leased.id,
               leased.fencing_token,
               worker_key,
               report,
               lease_now,
               lifecycle_now
             ) do
          {:ok, _allocation} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp workspace_setup_report({:ok, %{workspace_setup: report}}) when is_map(report),
    do: report

  defp workspace_setup_report({:error, {:safe, {:workspace_setup_failed, report}}})
       when is_map(report),
       do: report

  defp workspace_setup_report(
         {:error, {:uncertain, {:agent_launch_after_workspace_setup, _reason, report}}}
       )
       when is_map(report),
       do: report

  defp workspace_setup_report(
         {:error, {:uncertain, {:workspace_setup_cleanup_failed, _reason, report}}}
       )
       when is_map(report),
       do: report

  defp workspace_setup_report(_result), do: nil

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
