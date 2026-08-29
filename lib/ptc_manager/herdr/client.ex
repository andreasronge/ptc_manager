defmodule PtcManager.Herdr.Client do
  @moduledoc "Reads Herdr's JSON agent list without controlling any agent."

  @behaviour PtcManager.Herdr

  @impl true
  def list_agents do
    binary = Application.get_env(:ptc_manager, :herdr_binary, "herdr")
    session = Application.get_env(:ptc_manager, :herdr_session, "default")
    timeout = Application.get_env(:ptc_manager, :herdr_timeout_ms, 15_000)
    environment = herdr_environment(session)

    task =
      Task.async(fn ->
        execute(binary, environment)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, output, 0}} -> decode_agents(output)
      {:ok, {:ok, output, status}} -> {:error, {:herdr_exit, status, bounded(output)}}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :herdr_timeout}
    end
  end

  def decode_agents(output) when is_binary(output) do
    with {:ok, decoded} <- Jason.decode(output),
         {:ok, agents} <- extract_agents(decoded) do
      {:ok, agents}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_herdr_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_agents(agents) when is_list(agents), do: {:ok, agents}
  defp extract_agents(%{"agents" => agents}) when is_list(agents), do: {:ok, agents}

  defp extract_agents(%{"result" => %{"agents" => agents}}) when is_list(agents),
    do: {:ok, agents}

  defp extract_agents(%{"result" => agents}) when is_list(agents), do: {:ok, agents}
  defp extract_agents(_decoded), do: {:error, :unexpected_herdr_response}

  defp execute(binary, environment) do
    {output, status} =
      System.cmd(binary, ["agent", "list"], env: environment, stderr_to_stdout: true)

    {:ok, output, status}
  rescue
    error -> {:error, {:herdr_command_failed, error.__struct__}}
  end

  defp herdr_environment(session) do
    [{"HERDR_SESSION", session}]
    |> maybe_add_socket(Application.get_env(:ptc_manager, :herdr_socket_path))
  end

  defp maybe_add_socket(environment, path) when is_binary(path) and path != "",
    do: [{"HERDR_SOCKET_PATH", path} | environment]

  defp maybe_add_socket(environment, _path), do: environment

  defp bounded(output), do: output |> String.trim() |> String.slice(0, 500)
end
