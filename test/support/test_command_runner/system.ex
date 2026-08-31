defmodule PtcManager.TestCommandRunner.System do
  @moduledoc """
  Bounded runner for disposable, same-identity test commands.

  This helper deliberately does not model privileged production containment.
  Worker-owned commands require a worker-side timeout and kill protocol before
  the production `PtcManager.CommandRunner` boundary is connected to them.
  """

  @behaviour PtcManager.CommandRunner

  @default_output_limit 1_000_000

  @impl true
  def run(command, args, options) do
    timeout = Keyword.get(options, :timeout, 15_000)
    output_limit = Keyword.get(options, :output_limit, @default_output_limit)

    with {:ok, executable} <- executable(command) do
      port = Port.open({:spawn_executable, executable}, port_options(args, options))

      receive_command(
        port,
        "",
        output_limit,
        System.monotonic_time(:millisecond) + timeout
      )
    end
  rescue
    error in ErlangError -> {:error, {:command_failed, error.original}}
    error -> {:error, {:command_failed, error.__struct__}}
  catch
    :exit, reason -> {:error, {:command_failed, reason}}
  end

  defp receive_command(port, output, limit, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} when byte_size(output) + byte_size(data) <= limit ->
        receive_command(port, output <> data, limit, deadline)

      {^port, {:data, _data}} ->
        close_and_flush(port)
        {:error, :command_output_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, output}}
    after
      remaining ->
        close_and_flush(port)
        {:error, :timeout}
    end
  end

  defp close_and_flush(port) do
    Port.close(port)
    flush(port)
  rescue
    ArgumentError -> flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp executable(command) do
    case System.find_executable(command) do
      executable when is_binary(executable) -> {:ok, executable}
      nil -> {:error, {:command_failed, :enoent}}
    end
  end

  defp port_options(args, options) do
    [:binary, :exit_status, :hide, args: args]
    |> maybe_stderr_to_stdout(options)
    |> maybe_environment(options)
    |> maybe_working_directory(options)
  end

  defp maybe_stderr_to_stdout(port_options, options) do
    if Keyword.get(options, :stderr_to_stdout, false),
      do: [:stderr_to_stdout | port_options],
      else: port_options
  end

  defp maybe_environment(port_options, options) do
    case Keyword.fetch(options, :env) do
      {:ok, environment} -> [{:env, normalize_environment(environment)} | port_options]
      :error -> port_options
    end
  end

  defp maybe_working_directory(port_options, options) do
    case Keyword.fetch(options, :cd) do
      {:ok, directory} -> [{:cd, directory} | port_options]
      :error -> port_options
    end
  end

  defp normalize_environment(environment) do
    Enum.map(environment, fn
      {key, nil} -> {to_charlist(key), false}
      {key, value} -> {to_charlist(key), to_charlist(value)}
    end)
  end
end
