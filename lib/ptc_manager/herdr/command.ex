defmodule PtcManager.Herdr.Command do
  @moduledoc "Executes the Herdr CLI with a scrubbed environment and optional worker identity."

  alias PtcManager.Manager.CodexAdapter

  def run(args, timeout \\ nil) when is_list(args) do
    binary = Application.get_env(:ptc_manager, :herdr_binary, "herdr")
    timeout = timeout || Application.get_env(:ptc_manager, :herdr_timeout_ms, 15_000)
    {command, command_args} = command(binary, args)

    task =
      Task.async(fn ->
        System.cmd(command, command_args,
          env: environment(),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:herdr_exit, status, bounded(output)}}
      nil -> {:error, :herdr_timeout}
    end
  rescue
    error -> {:error, {:herdr_command_failed, error.__struct__}}
  end

  @doc false
  def command(binary, args) do
    session = Application.get_env(:ptc_manager, :herdr_session, "default")
    args = ["--session", session | args]

    case Application.get_env(:ptc_manager, :herdr_run_as_user) do
      user when is_binary(user) and user != "" ->
        {"/usr/bin/sudo", ["-n", "-H", "-u", user, "--", binary | args]}

      _user ->
        {binary, args}
    end
  end

  @doc false
  def environment do
    environment = CodexAdapter.command_environment()

    if Application.get_env(:ptc_manager, :herdr_run_as_user) in [nil, ""] do
      maybe_add_socket(environment, Application.get_env(:ptc_manager, :herdr_socket_path))
    else
      environment
    end
  end

  defp maybe_add_socket(environment, path) when is_binary(path) and path != "",
    do: List.keystore(environment, "HERDR_SOCKET_PATH", 0, {"HERDR_SOCKET_PATH", path})

  defp maybe_add_socket(environment, _path), do: environment
  defp bounded(output), do: output |> String.trim() |> String.slice(-1_000, 1_000)
end
