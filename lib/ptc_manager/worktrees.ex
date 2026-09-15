defmodule PtcManager.Worktrees do
  @moduledoc "Enforces worker-advertised worktree capacity and safe reclamation."

  require Logger

  alias PtcManager.Operations
  alias PtcManager.Operations.WorktreeAllocation
  alias PtcManager.ExternalPrSessions
  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Gateway
  alias PtcManager.Repository.{GitProbe, WorktreePreserver}
  alias PtcManager.WorktreeSecurity

  @missing_worktree_reason "Removed automatically: the worktree no longer existed on disk."
  @empty_worktree_reason "Removed automatically: the worktree was clean with no commits beyond the default branch."

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

  @doc "Runs one terminal cleanup and, when nothing terminal is waiting, one abandoned-worktree cleanup."
  def cleanup_once(
        adapter \\ configured_adapter(),
        probe \\ GitProbe,
        external_adapter \\ configured_external_adapter()
      ) do
    reap_investigation_worktree()

    case cleanup_terminal_once(adapter, probe, external_adapter) do
      {:ok, :empty} -> cleanup_abandoned_once(adapter, probe)
      other -> other
    end
  end

  defp reap_investigation_worktree do
    adapter =
      Application.get_env(
        :ptc_manager,
        :investigation_workspace_adapter,
        HerdrAdapter
      )

    case PtcManager.InvestigationWorkspaces.cleanup_terminal_once(adapter) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Investigation workspace cleanup deferred: #{inspect(reason)}")
    end
  end

  @doc """
  Removes one retained `attention` worktree that provably holds nothing worth keeping.

  A lost or failed attempt keeps its worktree because the coordinator cannot
  know whether uncommitted work matters. Two cases carry no such risk: the
  directory no longer exists inside a healthy worktree root, or a credential-free
  Git check proves the checkout is clean with no commit beyond the default
  branch. Everything else waits for a maintainer's explicit discard.
  """
  def cleanup_abandoned_once(adapter \\ configured_adapter(), probe \\ GitProbe) do
    :ok = Operations.recover_expired_worktree_preservations()

    candidate =
      Operations.list_workers_with_worktrees()
      |> Enum.flat_map(& &1.worktree_allocations)
      |> Enum.filter(&(&1.state == "attention"))
      |> Enum.sort_by(&{&1.last_used_at, &1.id})
      |> Enum.find_value(fn allocation ->
        case abandoned_reason(allocation, probe) do
          {:ok, reason} -> {allocation, reason}
          :keep -> nil
        end
      end)

    case candidate do
      nil ->
        {:ok, :empty}

      {allocation, reason} ->
        remove_retained(allocation, adapter, :remove_worktree, %{
          actor: "coordinator",
          reason: reason
        })
    end
  end

  @doc "Preserves one retained worktree as a bundle and patch, then removes it."
  def preserve_attention(
        allocation_id,
        actor,
        adapter \\ configured_adapter(),
        preserver \\ configured_preserver()
      )
      when is_integer(allocation_id) and is_binary(actor) and actor != "" do
    case Operations.get_worktree_allocation(allocation_id) do
      nil ->
        {:error, :worktree_allocation_missing}

      %WorktreeAllocation{state: "attention"} = allocation ->
        if discardable?(allocation) do
          preserve_and_remove(allocation, actor, adapter, preserver)
        else
          {:error, :worktree_in_use}
        end

      %WorktreeAllocation{} ->
        {:error, :worktree_not_retained}
    end
  end

  @doc "Force-removes one retained `attention` worktree on a maintainer's explicit instruction."
  def discard_attention(allocation_id, actor, adapter \\ configured_adapter())
      when is_integer(allocation_id) and is_binary(actor) and actor != "" do
    case Operations.get_worktree_allocation(allocation_id) do
      nil ->
        {:error, :worktree_allocation_missing}

      %WorktreeAllocation{state: "attention"} = allocation ->
        if discardable?(allocation) do
          remove_retained(allocation, adapter, :discard_worktree, %{
            actor: actor,
            reason: "Discarded by the maintainer; uncommitted work was not kept."
          })
        else
          {:error, :worktree_in_use}
        end

      %WorktreeAllocation{} ->
        {:error, :worktree_not_retained}
    end
  end

  defp preserve_and_remove(allocation, actor, adapter, preserver) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, claimed, token} <-
           Operations.claim_worktree_cleanup(allocation.id, now,
             from: ["attention"],
             purpose: "preservation"
           ),
         {:ok, preservation} <- preserver.preserve(claimed, token),
         {:ok, preserved} <-
           Operations.record_worktree_preservation(claimed.id, token, preservation),
         :ok <-
           remove_claimed(preserved, adapter, token, :discard_worktree, %{
             actor: actor,
             reason: "Preserved as #{preservation.preserved_artifact_path} before removal."
           }) do
      :ok
    else
      {:error, :worktree_cleanup_already_claimed} = error ->
        error

      {:error, reason, claimed, token} ->
        _ = Operations.fail_worktree_cleanup(claimed.id, token, reason)
        {:error, {:worktree_cleanup_failed, reason}}

      {:error, reason} ->
        fail_preservation_claim(allocation.id, reason)
    end
  end

  defp fail_preservation_claim(allocation_id, reason) do
    case Operations.get_worktree_allocation(allocation_id) do
      %{state: "cleaning", cleanup_token: token} ->
        _ = Operations.fail_worktree_cleanup(allocation_id, token, reason)

      _allocation ->
        :ok
    end

    {:error, {:worktree_preservation_failed, reason}}
  end

  defp discardable?(allocation) do
    not ((PtcManager.Reviews.held?(allocation.job) and
            not cancelled_agent_stopped?(allocation.job)) or
           Operations.worktree_consumes_execution_slot?(allocation))
  end

  # Synchronization still holds cancelled jobs; only an explicit discard may
  # release their workspace after durable stop confirmation.
  defp cancelled_agent_stopped?(%{
         state: "cancelled",
         review_state: "cancelled",
         review_resume_expires_at: nil,
         review_recovery_expires_at: nil,
         last_error: nil,
         fencing_token: fence,
         agent_runs: runs
       })
       when is_list(runs) do
    Enum.any?(
      runs,
      &(&1.role == "implementer" and &1.fencing_token == fence and &1.state == "lost")
    ) and
      Enum.all?(runs, &(&1.role != "implementer" or &1.state in ~w(done failed lost)))
  end

  defp cancelled_agent_stopped?(_), do: false

  defp abandoned_reason(allocation, probe) do
    cond do
      PtcManager.Reviews.held?(allocation.job) -> :keep
      Operations.worktree_consumes_execution_slot?(allocation) -> :keep
      not managed_path?(allocation.path) -> :keep
      not File.exists?(allocation.path) -> {:ok, @missing_worktree_reason}
      not real_directory?(allocation.path) -> :keep
      empty_worktree?(allocation, probe) -> {:ok, @empty_worktree_reason}
      true -> observe_retained_work(allocation, probe)
    end
  end

  # A missing directory only proves abandonment when the managed root itself
  # is present and intact. Managed allocations are direct children: accepting
  # deeper paths would let a worker-owned symlink redirect deletion elsewhere.
  # Reject unnormalised paths too, since symlink/.. has filesystem semantics
  # that differ from Path.expand/1.
  defp managed_path?(path) when is_binary(path) do
    root = Application.get_env(:ptc_manager, :worktree_root)

    is_binary(root) and Path.type(path) == :absolute and File.dir?(root) and
      WorktreeSecurity.validate_configured_root(root) == :ok and
      path == Path.expand(path) and Path.dirname(path) == Path.expand(root) and
      not match?({:ok, %{type: :symlink}}, File.lstat(path))
  end

  defp managed_path?(_path), do: false

  defp real_directory?(path) do
    match?({:ok, %{type: :directory}}, File.lstat(path))
  end

  defp empty_worktree?(%{path: path, job: %{repository: %{default_branch: branch}}}, probe)
       when is_binary(branch) do
    probe.empty_worktree(path, branch) == :ok
  end

  defp empty_worktree?(_allocation, _probe), do: false

  defp observe_retained_work(
         %{path: path, job: %{repository: %{default_branch: branch}}} = allocation,
         probe
       )
       when is_binary(branch) do
    if function_exported?(probe, :retained_work, 2) do
      case probe.retained_work(path, branch) do
        {:ok, observation} ->
          Operations.record_retained_work_observation(allocation.id, observation)

        {:error, _reason} ->
          :ok
      end
    end

    :keep
  end

  defp observe_retained_work(_allocation, _probe), do: :keep

  defp remove_retained(allocation, adapter, function, audit) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, claimed, token} <-
           Operations.claim_worktree_cleanup(allocation.id, now, from: ["attention"]),
         :ok <- remove_claimed(claimed, adapter, token, function, audit) do
      :ok
    else
      {:error, :worktree_cleanup_already_claimed} ->
        {:error, :worktree_cleanup_already_claimed}

      {:error, reason, claimed, token} ->
        _ = Operations.fail_worktree_cleanup(claimed.id, token, reason)
        {:error, {:worktree_cleanup_failed, reason}}
    end
  end

  def cleanup_terminal_once(
        adapter \\ configured_adapter(),
        probe \\ GitProbe,
        external_adapter \\ configured_external_adapter()
      ) do
    case ExternalPrSessions.cleanup_terminal_once(external_adapter) do
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
          ((allocation.state == "cleaning" and
              (is_nil(allocation.cleanup_purpose) or allocation.cleanup_purpose != "preservation") and
              allocation.cleanup_expires_at) &&
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

  defp remove_claimed(allocation, adapter, token, function \\ :remove_worktree, audit \\ nil) do
    case Gateway.call(adapter, removal_function(adapter, function), [allocation]) do
      :ok ->
        complete_claimed(allocation, token, audit)

      {:error, :worktree_workspace_forgotten} ->
        case discard_forgotten_directory(allocation) do
          :ok -> complete_claimed(allocation, token, audit)
          {:error, reason} -> {:error, reason, allocation, token}
        end

      {:error, reason} ->
        {:error, reason, allocation, token}

      other ->
        {:error, {:unexpected_worktree_cleanup_result, other}, allocation, token}
    end
  end

  defp complete_claimed(allocation, token, audit) do
    case Operations.complete_worktree_cleanup(allocation.id, token, audit) do
      {:ok, _allocation} -> :ok
      {:error, reason} -> {:error, reason, allocation, token}
    end
  end

  # Herdr has forgotten the workspace, so nothing else will ever remove the
  # directory it left behind and the cleanup would fail forever instead. Doing
  # it here is only safe inside the validated managed root, which is the guard
  # the abandonment probe already applies before it trusts a path.
  defp discard_forgotten_directory(%{path: path}) when is_binary(path) do
    if managed_path?(path) do
      remove_directory(path)
    else
      {:error, :worktree_path_outside_managed_root}
    end
  end

  defp discard_forgotten_directory(_allocation), do: {:error, :worktree_path_missing}

  # The root is worker-owned in production. Use its OS identity for removal,
  # keeping the coordinator's claim and path checks above as the authority.
  defp remove_directory(path) do
    user = Application.get_env(:ptc_manager, :herdr_run_as_user)
    root = Application.fetch_env!(:ptc_manager, :worktree_root) |> Path.expand()

    {binary, args} =
      if user in [nil, ""] do
        {"/usr/bin/python3",
         ["-I", Application.app_dir(:ptc_manager, "priv/worktree_cleanup.py"), root, path]}
      else
        PtcManager.CommandEnvironment.command(
          "/usr/local/bin/ptc-manager-worker-worktree-cleanup",
          [root, path],
          user
        )
      end

    case System.cmd(binary, args,
           stderr_to_stdout: true,
           env: PtcManager.CommandEnvironment.scrub()
         ) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:worktree_directory_removal_failed, status}}
    end
  rescue
    _error -> {:error, :worktree_directory_removal_unavailable}
  end

  # Adapters may omit the forced removal; fall back to the ordinary one.
  defp removal_function(adapter, :discard_worktree) do
    module = adapter_module(adapter)

    if Code.ensure_loaded?(module) and function_exported?(module, :discard_worktree, 1),
      do: :discard_worktree,
      else: :remove_worktree
  end

  defp removal_function(_adapter, function), do: function

  defp adapter_module(%module{}), do: module
  defp adapter_module(module) when is_atom(module), do: module

  defp configured_adapter,
    do: Application.fetch_env!(:ptc_manager, :dispatch_adapter)

  defp configured_external_adapter,
    do: Application.get_env(:ptc_manager, :pull_request_herdr_adapter, HerdrAdapter)

  defp configured_preserver,
    do: Application.get_env(:ptc_manager, :worktree_preserver, WorktreePreserver)
end
