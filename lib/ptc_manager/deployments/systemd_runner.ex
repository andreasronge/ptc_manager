defmodule PtcManager.Deployments.SystemdRunner do
  @moduledoc false

  @behaviour PtcManager.Deployments.Runner

  alias PtcManager.CommandEnvironment
  alias PtcManager.Deployments.Deployment
  alias PtcManager.Repository.Contract

  @unit "ptc-manager-self-deploy.service"

  @impl true
  def start(%Deployment{repository: repository} = deployment, %Contract{} = contract) do
    with {:ok, command} <- Contract.deployment_script(contract),
         {:ok, spool} <- spool_path(),
         :ok <- File.mkdir_p(spool),
         :ok <- write_request(spool, deployment, repository, command, contract),
         :ok <- trigger() do
      :ok
    end
  end

  defp write_request(spool, deployment, repository, command, contract) do
    status_path = Path.join(spool, "deployment-#{deployment.id}.status.json")

    request = %{
      "deployment_id" => deployment.id,
      "repository" => "#{repository.github_owner}/#{repository.github_name}",
      "default_branch" => repository.default_branch,
      "source_path" => repository.local_path,
      "requested_sha" => deployment.requested_sha,
      "command" => command,
      "timeout_seconds" => contract.deployment_timeout_minutes * 60,
      "status_path" => status_path
    }

    target = Path.join(spool, "request.json")
    temporary = target <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, Jason.encode!(request) <> "\n", [:binary]),
         :ok <- File.chmod(temporary, 0o640),
         :ok <- File.rename(temporary, target) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:deployment_request_write_failed, reason}}
    end
  end

  defp trigger do
    case Application.get_env(:ptc_manager, :deployment_systemctl_command) do
      command when is_binary(command) and command != "" ->
        args =
          Application.get_env(
            :ptc_manager,
            :deployment_systemctl_args,
            ["-n", "/bin/systemctl", "start", "--no-block", @unit]
          )

        case System.cmd(command, args,
               env: CommandEnvironment.scrub(),
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:deployment_trigger_failed, status, bounded(output)}}
        end

      _missing ->
        {:error, :deployment_runner_not_configured}
    end
  rescue
    error -> {:error, {:deployment_trigger_failed, error.__struct__}}
  end

  defp spool_path do
    case Application.get_env(:ptc_manager, :deployment_spool_path) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, :invalid_deployment_spool_path}

      _path ->
        {:error, :invalid_deployment_spool_path}
    end
  end

  defp bounded(value), do: value |> to_string() |> String.slice(0, 2_000)
end
