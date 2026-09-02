defmodule PtcManager.Deployments.SystemdRunnerTest do
  use ExUnit.Case, async: false

  alias PtcManager.Deployments.{Deployment, SystemdRunner}
  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.Contract

  test "writes a bounded typed request before triggering the host service" do
    spool =
      Path.join(System.tmp_dir!(), "ptc-systemd-runner-#{System.unique_integer([:positive])}")

    previous_spool = Application.get_env(:ptc_manager, :deployment_spool_path)
    previous_command = Application.get_env(:ptc_manager, :deployment_systemctl_command)
    previous_args = Application.get_env(:ptc_manager, :deployment_systemctl_args)

    on_exit(fn ->
      restore(:deployment_spool_path, previous_spool)
      restore(:deployment_systemctl_command, previous_command)
      restore(:deployment_systemctl_args, previous_args)
      File.rm_rf!(spool)
    end)

    Application.put_env(:ptc_manager, :deployment_spool_path, spool)
    Application.put_env(:ptc_manager, :deployment_systemctl_command, "/usr/bin/true")
    Application.put_env(:ptc_manager, :deployment_systemctl_args, [])

    repository = %Repository{
      id: 7,
      github_owner: "andreasronge",
      github_name: "ptc_manager",
      default_branch: "main",
      local_path: "/srv/ptc_manager"
    }

    deployment = %Deployment{
      id: 42,
      repository: repository,
      requested_sha: String.duplicate("a", 40)
    }

    contract = %Contract{
      version: 1,
      bootstrap_command: "./scripts/ptc/bootstrap",
      bootstrap_timeout_minutes: 10,
      deployment_command: "./scripts/ptc/deploy",
      deployment_timeout_minutes: 20
    }

    assert :ok = SystemdRunner.start(deployment, contract)
    request = spool |> Path.join("deployment-42.request.json") |> File.read!() |> Jason.decode!()
    assert request["deployment_id"] == 42
    assert request["requested_sha"] == String.duplicate("a", 40)
    assert request["command"] == "scripts/ptc/deploy"
    assert request["timeout_seconds"] == 1_200
    assert request["status_path"] == Path.join(spool, "deployment-42.status.json")
  end

  test "removes the request when the host trigger fails" do
    spool =
      Path.join(System.tmp_dir!(), "ptc-systemd-failure-#{System.unique_integer([:positive])}")

    previous_spool = Application.get_env(:ptc_manager, :deployment_spool_path)
    previous_command = Application.get_env(:ptc_manager, :deployment_systemctl_command)
    previous_args = Application.get_env(:ptc_manager, :deployment_systemctl_args)

    on_exit(fn ->
      restore(:deployment_spool_path, previous_spool)
      restore(:deployment_systemctl_command, previous_command)
      restore(:deployment_systemctl_args, previous_args)
      File.rm_rf!(spool)
    end)

    Application.put_env(:ptc_manager, :deployment_spool_path, spool)
    Application.put_env(:ptc_manager, :deployment_systemctl_command, "/usr/bin/false")
    Application.put_env(:ptc_manager, :deployment_systemctl_args, [])

    repository = %Repository{
      id: 7,
      github_owner: "owner",
      github_name: "repo",
      default_branch: "main"
    }

    deployment = %Deployment{
      id: 9,
      repository: repository,
      requested_sha: String.duplicate("a", 40)
    }

    contract = %Contract{
      version: 1,
      bootstrap_command: "./scripts/ptc/bootstrap",
      bootstrap_timeout_minutes: 10,
      deployment_command: "./scripts/ptc/deploy",
      deployment_timeout_minutes: 20
    }

    assert {:error, {:deployment_trigger_failed, 1, _output}} =
             SystemdRunner.start(deployment, contract)

    refute File.exists?(Path.join(spool, "deployment-9.request.json"))
  end

  test "retires an inactive stale request before starting a new deployment" do
    spool =
      Path.join(System.tmp_dir!(), "ptc-systemd-stale-#{System.unique_integer([:positive])}")

    previous_spool = Application.get_env(:ptc_manager, :deployment_spool_path)
    previous_command = Application.get_env(:ptc_manager, :deployment_systemctl_command)
    previous_args = Application.get_env(:ptc_manager, :deployment_systemctl_args)
    previous_status = Application.get_env(:ptc_manager, :deployment_systemctl_status_command)

    on_exit(fn ->
      restore(:deployment_spool_path, previous_spool)
      restore(:deployment_systemctl_command, previous_command)
      restore(:deployment_systemctl_args, previous_args)
      restore(:deployment_systemctl_status_command, previous_status)
      File.rm_rf!(spool)
    end)

    File.mkdir_p!(spool)
    File.write!(Path.join(spool, "deployment-1.request.json"), "stale")
    Application.put_env(:ptc_manager, :deployment_spool_path, spool)
    Application.put_env(:ptc_manager, :deployment_systemctl_command, "/usr/bin/true")
    Application.put_env(:ptc_manager, :deployment_systemctl_args, [])
    Application.delete_env(:ptc_manager, :deployment_systemctl_status_command)

    repository = %Repository{
      id: 7,
      github_owner: "owner",
      github_name: "repo",
      default_branch: "main"
    }

    deployment = %Deployment{
      id: 2,
      repository: repository,
      requested_sha: String.duplicate("a", 40)
    }

    contract = %Contract{
      version: 1,
      bootstrap_command: "./scripts/ptc/bootstrap",
      bootstrap_timeout_minutes: 10,
      deployment_command: "./scripts/ptc/deploy",
      deployment_timeout_minutes: 20
    }

    assert :ok = SystemdRunner.start(deployment, contract)
    refute File.exists?(Path.join(spool, "deployment-1.request.json"))
    assert File.exists?(Path.join(spool, "deployment-2.request.json"))
  end

  defp restore(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore(key, value), do: Application.put_env(:ptc_manager, key, value)
end
