defmodule PtcManager.ResourceOperationRecovery do
  @moduledoc false

  alias PtcManager.CommandEnvironment
  alias PtcManager.Operations.ResourceOperation

  def recover(
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

  def recover(
        %ResourceOperation{state: "recovery_pending", cgroup_path: nil, wrapper_pid: nil} =
          operation
      ) do
    recover_starting_lock(operation)
  end

  # A heartbeat can be delayed by the same transient database contention that
  # moved the operation into recovery_pending. Without a cgroup we cannot
  # prove the process tree stopped, so keep the slot fenced and give the live
  # wrapper time to heartbeat itself back to running before escalating.
  def recover(%ResourceOperation{}),
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

    socket_path = Application.get_env(:ptc_manager, :resource_operation_socket_path)
    lock_path = Path.join(Path.dirname(socket_path), "operation-slot-#{slot_number}.lock")

    args = [
      "-n",
      helper,
      Integer.to_string(operation.id),
      operation.attempt_token,
      path,
      Integer.to_string(wrapper_pid),
      lock_path
    ]

    case System.cmd(command, args, env: CommandEnvironment.scrub(), stderr_to_stdout: true) do
      {_output, 0} -> :recovered
      {output, 75} -> {:retry, bounded(output)}
      {output, status} -> {:error, {:operation_recovery_failed, status, bounded(output)}}
    end
  rescue
    error -> {:error, {:operation_recovery_failed, error.__struct__}}
  end

  defp bounded(value), do: value |> to_string() |> String.trim() |> String.slice(0, 1_000)
end
