defmodule PtcManager.Repository.WorkerGit do
  @moduledoc "Runs Git commands through the configured Herdr worker identity."

  alias PtcManager.CommandEnvironment

  @output_limit 65_536

  def run(args) when is_list(args) do
    run(args, Application.get_env(:ptc_manager, :herdr_git_timeout_ms, 60_000))
  end

  def run(args, timeout_ms)
      when is_list(args) and is_integer(timeout_ms) and timeout_ms > 0 do
    {command, command_args} = command_spec(args)
    executable = System.find_executable(command) || command
    started = System.monotonic_time(:millisecond)

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: command_args,
          env: command_environment()
        ]
      )

    receive_result(
      port,
      "",
      started + timeout_ms
    )
  rescue
    error -> {Exception.message(error), 127}
  end

  def command_spec(args) when is_list(args) do
    binary =
      Application.get_env(
        :ptc_manager,
        :herdr_git_binary,
        Application.get_env(:ptc_manager, :git_binary, "git")
      )

    CommandEnvironment.command(
      binary,
      args,
      Application.get_env(:ptc_manager, :herdr_run_as_user)
    )
  end

  defp receive_result(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_result(port, append_bounded(output, data), deadline)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      remaining ->
        close_port(port)
        {append_bounded(output, "\nWorker Git command timed out."), 124}
    end
  end

  defp append_bounded(output, data) do
    output = output <> String.replace_invalid(data)

    if byte_size(output) <= @output_limit,
      do: output,
      else: binary_part(output, byte_size(output) - @output_limit, @output_limit)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp command_environment do
    CommandEnvironment.scrub()
    |> List.keystore("GIT_TERMINAL_PROMPT", 0, {"GIT_TERMINAL_PROMPT", "0"})
    |> Enum.map(fn
      {key, nil} -> {to_charlist(key), false}
      {key, value} -> {to_charlist(key), to_charlist(value)}
    end)
  end
end
