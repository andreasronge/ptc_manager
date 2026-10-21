defmodule PtcManager.ResourceOperationRecovery do
  @moduledoc """
  Decides what happens to an operation whose wrapper can no longer vouch for it.

  A Linux host recovers it through its cgroup, or escalates to maintenance
  when it cannot. A host without containment (macOS, development) has no
  evidence that the command stopped, so the operation stays fenced and holds
  its slot until a maintainer releases it with `release/4`.
  """

  require Logger

  alias PtcManager.{CommandEnvironment, Host, ManagedOperationContext, ResourceOperations}
  alias PtcManager.Operations.ResourceOperation

  def recover(%ResourceOperation{} = operation) do
    case Host.uncertain_operation_policy() do
      :escalate -> recover_with_containment(operation)
      :fence -> {:fenced, inspect_operation(operation)}
    end
  end

  defp recover_with_containment(
         %ResourceOperation{
           cgroup_path: path,
           wrapper_pid: wrapper_pid,
           slot_number: slot_number
         } = operation
       )
       when is_binary(path) and path != "" and is_integer(wrapper_pid) and wrapper_pid > 0 and
              is_integer(slot_number) and slot_number > 0 do
    run_helper(operation, path, wrapper_pid)
  end

  defp recover_with_containment(
         %ResourceOperation{state: "recovery_pending", cgroup_path: nil, wrapper_pid: nil} =
           operation
       ) do
    recover_starting_lock(operation)
  end

  # A heartbeat can be delayed by the same transient database contention that
  # moved the operation into recovery_pending. Without a cgroup we cannot
  # prove the process tree stopped, so keep the slot fenced and give the live
  # wrapper time to heartbeat itself back to running before escalating.
  defp recover_with_containment(%ResourceOperation{}),
    do: {:retry, :operation_recovery_requires_cgroup_containment}

  defp recover_starting_lock(%ResourceOperation{slot_number: slot_number} = operation)
       when is_integer(slot_number) and slot_number > 0 do
    run_helper(operation, "-", 0)
  end

  defp recover_starting_lock(%ResourceOperation{}),
    do: {:error, :operation_recovery_identity_missing}

  defp run_helper(%ResourceOperation{slot_number: slot_number} = operation, path, wrapper_pid) do
    command =
      Application.get_env(:ptc_manager, :resource_operation_recovery_command, "/usr/bin/sudo")

    helper =
      Application.get_env(
        :ptc_manager,
        :resource_operation_recovery_helper,
        "/usr/local/bin/ptc-manager-operation-recover"
      )

    args = [
      "-n",
      helper,
      Integer.to_string(operation.id),
      operation.attempt_token,
      path,
      Integer.to_string(wrapper_pid),
      lock_path(slot_number)
    ]

    case System.cmd(command, args, env: CommandEnvironment.scrub(), stderr_to_stdout: true) do
      {_output, 0} -> :recovered
      {output, 75} -> {:retry, bounded(output)}
      {output, status} -> {:error, {:operation_recovery_failed, status, bounded(output)}}
    end
  rescue
    error -> {:error, {:operation_recovery_failed, error.__struct__}}
  end

  @inspect_timeout_ms 15_000

  @doc """
  What can be seen of a fenced operation now: the processes still carrying its
  attempt marker, whether its wrapper pid exists, and whether its slot lock is
  free. The installed wrapper does the looking, so the listing is the one the
  wrapper itself trusts. Nothing here is evidence that the command stopped.
  """
  def inspect_operation(%ResourceOperation{} = operation) do
    wrapper = Host.path(:operation_wrapper)

    args = [
      "inspect",
      "--marker",
      "#{operation.id}-#{String.slice(operation.attempt_token || "", 0, 12)}",
      "--lock",
      lock_path(operation.slot_number),
      "--wrapper-pid",
      Integer.to_string(operation.wrapper_pid || 0)
    ]

    # A missing or unrunnable wrapper is evidence too; it must not take the
    # broker or the page down with it.
    task =
      Task.async(fn ->
        try do
          System.cmd(wrapper, args, env: CommandEnvironment.scrub(), stderr_to_stdout: true)
        rescue
          error -> {:could_not_run, Exception.message(error)}
        end
      end)

    result =
      case Task.yield(task, @inspect_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          case Jason.decode(output) do
            {:ok, %{"processes" => processes, "lock" => lock} = evidence}
            when is_list(processes) and is_binary(lock) ->
              Map.take(evidence, ["processes", "listing_error", "wrapper_alive", "lock"])

            _invalid ->
              %{"inspection_error" => "the wrapper answered with something other than evidence"}
          end

        {:ok, {:could_not_run, message}} ->
          %{"inspection_error" => "the wrapper could not run: #{bounded(message)}"}

        {:ok, {output, status}} ->
          %{"inspection_error" => "the wrapper exited #{status}: #{bounded(output)}"}

        nil ->
          %{"inspection_error" => "the wrapper did not answer within 15 seconds"}
      end

    %{"wrapper_pid" => operation.wrapper_pid, "slot_number" => operation.slot_number}
    |> Map.merge(result)
    |> unseen_agent_processes()
  end

  # The listing covers this account's processes only. Agents under their own
  # account are out of its sight, so an empty list proves nothing there.
  defp unseen_agent_processes(evidence) do
    case Host.agent_identity() do
      {:separate, user} ->
        unseen =
          "processes of the agent account #{user} cannot be listed from the service account"

        Map.update(evidence, "listing_error", unseen, &(&1 || unseen))

      :service_account ->
        evidence
    end
  end

  @doc """
  Releases a fenced or escalated operation for a maintainer. The slot lock
  must be free, so its wrapper is gone; processes that still carry the attempt
  marker, or a listing that failed, need `accept_processes?`. The release itself is one guarded update
  that loses to any heartbeat, finish or cancel that changed the operation
  first.
  """
  def release(%ResourceOperation{} = operation, actor, accept_processes?)
      when is_binary(actor) do
    evidence = inspect_operation(operation)

    cond do
      not ResourceOperations.awaiting_maintainer?(operation) ->
        {:error, :operation_not_fenced}

      evidence["lock"] == "held" ->
        {:error, {:slot_lock_held, operation.wrapper_pid}}

      evidence["lock"] != "free" ->
        {:error, {:slot_lock_unknown, evidence["inspection_error"] || evidence["lock"]}}

      processes_may_remain?(evidence) and not accept_processes? ->
        {:error, :processes_listed}

      true ->
        result = ResourceOperations.release_fenced(operation, actor, evidence)

        with {:ok, released} <- result do
          Logger.warning(
            "Resource operation #{released.id} released by #{actor} " <>
              "with #{length(evidence["processes"])} listed processes"
          )
        end

        result
    end
  end

  @doc "True unless the listing ran and found nothing carrying the marker."
  def processes_may_remain?(evidence),
    do: evidence["processes"] != [] or not is_nil(evidence["listing_error"])

  defp lock_path(slot_number),
    do: Path.join(ManagedOperationContext.lock_directory(), "operation-slot-#{slot_number}.lock")

  defp bounded(value), do: value |> to_string() |> String.trim() |> String.slice(0, 1_000)
end
