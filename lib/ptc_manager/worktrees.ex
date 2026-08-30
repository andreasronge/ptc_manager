defmodule PtcManager.Worktrees do
  @moduledoc "Enforces worker-advertised worktree capacity and safe reclamation."

  alias PtcManager.Operations
  alias PtcManager.ExternalPrSessions
  alias PtcManager.Repository.GitProbe

  def ensure_slot(worker_key, capacity, adapter, probe \\ GitProbe)

  def ensure_slot(_worker_key, capacity, _adapter, _probe)
      when not is_integer(capacity) or capacity < 1,
      do: {:error, :invalid_agent_capacity}

  def ensure_slot(worker_key, capacity, _adapter, _probe) when is_binary(worker_key) do
    allocations = Operations.list_occupying_worktrees(worker_key)

    active_count =
      Enum.count(allocations, &Operations.worktree_consumes_execution_slot?/1)

    if active_count < capacity do
      :ok
    else
      {:error, :worktree_capacity}
    end
  end

  def cleanup_terminal_once(adapter \\ configured_adapter(), probe \\ GitProbe) do
    case ExternalPrSessions.cleanup_terminal_once() do
      {:ok, :empty} -> cleanup_managed_terminal_once(adapter, probe)
      other -> other
    end
  end

  defp cleanup_managed_terminal_once(adapter, probe) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    candidate =
      Operations.list_workers_with_worktrees()
      |> Enum.flat_map(& &1.worktree_allocations)
      |> Enum.filter(fn allocation ->
        allocation.state == "terminal" or
          ((allocation.state == "cleaning" and allocation.cleanup_expires_at) &&
             DateTime.compare(allocation.cleanup_expires_at, now) != :gt)
      end)
      |> Enum.min_by(&{&1.last_used_at, &1.id}, fn -> nil end)

    case candidate do
      nil -> {:ok, :empty}
      allocation -> remove(allocation, adapter, probe)
    end
  end

  defp remove(allocation, adapter, probe) do
    with {:ok, claimed, token} <- Operations.claim_worktree_cleanup(allocation.id),
         :ok <- verify_clean_head(claimed, probe),
         :ok <- remove_claimed(claimed, adapter, token) do
      :ok
    else
      {:error, :worktree_cleanup_already_claimed} ->
        {:error, :worktree_cleanup_already_claimed}

      {:error, reason, claimed, token} ->
        _ = Operations.fail_worktree_cleanup(claimed.id, token, reason)
        {:error, {:worktree_cleanup_failed, reason}}
    end
  end

  defp verify_clean_head(
         %{job: %{state: job_state, pr_publication: %{pr_state: pr_state}}},
         _probe
       )
       when job_state in ["done", "cancelled"] and pr_state in ["merged", "closed"],
       do: :ok

  defp verify_clean_head(%{path: path, job: job} = allocation, probe)
       when is_binary(path) and is_binary(allocation.head_sha) do
    case probe.reclaimable(path, job.branch_name, allocation.head_sha) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, reason, allocation, allocation.cleanup_token}

      other ->
        {:error, {:unexpected_git_probe_result, other}, allocation, allocation.cleanup_token}
    end
  end

  defp verify_clean_head(allocation, _probe),
    do: {:error, :worktree_clean_head_unavailable, allocation, allocation.cleanup_token}

  defp remove_claimed(allocation, adapter, token) do
    case adapter.remove_worktree(allocation) do
      :ok ->
        case Operations.complete_worktree_cleanup(allocation.id, token) do
          {:ok, _allocation} -> :ok
          {:error, reason} -> {:error, reason, allocation, token}
        end

      {:error, reason} ->
        {:error, reason, allocation, token}

      other ->
        {:error, {:unexpected_worktree_cleanup_result, other}, allocation, token}
    end
  end

  defp configured_adapter,
    do: Application.fetch_env!(:ptc_manager, :dispatch_adapter)
end
