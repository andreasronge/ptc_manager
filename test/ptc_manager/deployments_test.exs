defmodule PtcManager.DeploymentsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Deployments
  alias PtcManager.Deployments.Deployment
  alias PtcManager.Operations.AgentRun
  alias PtcManager.{OperationalMode, Repo}

  defmodule RevisionSource do
    def latest(_repository), do: {:ok, Application.fetch_env!(:ptc_manager, :test_latest_sha)}
  end

  defmodule Runner do
    def start(deployment, contract) do
      send(
        Application.fetch_env!(:ptc_manager, :deployment_test_pid),
        {:deployment_started, deployment, contract}
      )

      :ok
    end
  end

  setup do
    previous =
      Map.new(
        [:deployment_revision_source, :deployment_runner, :deployment_spool_path, :deployed_sha],
        &{&1, Application.get_env(:ptc_manager, &1)}
      )

    spool =
      Path.join(
        System.tmp_dir!(),
        "ptc-deployments-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:ptc_manager, :deployment_revision_source, RevisionSource)
    Application.put_env(:ptc_manager, :deployment_runner, Runner)
    Application.put_env(:ptc_manager, :deployment_test_pid, self())
    Application.put_env(:ptc_manager, :deployment_spool_path, spool)
    Application.put_env(:ptc_manager, :test_latest_sha, String.duplicate("b", 40))
    Application.put_env(:ptc_manager, :deployed_sha, String.duplicate("a", 40))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)

      Application.delete_env(:ptc_manager, :deployment_test_pid)
      Application.delete_env(:ptc_manager, :test_latest_sha)
      if OperationalMode.mode() == :draining, do: OperationalMode.leave_draining()
      File.rm_rf!(spool)
    end)

    %{spool: spool}
  end

  test "deployment drains new work and launches only after active managed runs finish" do
    repository = deployable_repository()
    worker = worker_fixture()
    now = now()

    run =
      %AgentRun{}
      |> AgentRun.changeset(%{
        worker_id: worker.id,
        role: "implementer",
        state: "working",
        started_at: now,
        last_heartbeat_at: now
      })
      |> Repo.insert!()

    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert deployment.state == "draining"
    assert OperationalMode.mode() == :draining
    refute_receive {:deployment_started, _, _}, 100

    assert Deployments.advance() in [:ok, :idle]
    refute_receive {:deployment_started, _, _}, 100

    run
    |> AgentRun.changeset(%{state: "done", ended_at: now()})
    |> Repo.update!()

    assert Deployments.advance() in [:ok, :idle]
    assert_receive {:deployment_started, started, contract}
    assert started.requested_sha == String.duplicate("b", 40)
    assert contract.deployment_command == "./scripts/ptc/deploy"
    assert Repo.get!(Deployment, deployment.id).state == "running"
  end

  test "a host status file completes the persisted deployment", %{spool: spool} do
    repository = deployable_repository()
    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert :ok = Deployments.advance()
    assert_receive {:deployment_started, _, _}

    File.mkdir_p!(spool)

    File.write!(
      Path.join(spool, "deployment-#{deployment.id}.status.json"),
      Jason.encode!(%{
        "deployment_id" => deployment.id,
        "requested_sha" => deployment.requested_sha,
        "state" => "completed",
        "release_id" => "bbbbbbbbbbbb",
        "status_text" => "Health checks passed.",
        "error" => nil
      })
    )

    assert Deployments.advance() in [:ok, :idle]
    completed = Repo.get!(Deployment, deployment.id)
    assert completed.state == "completed"
    assert completed.finished_at
    assert completed.status_text == "Health checks passed."
    assert OperationalMode.mode() == :active
  end

  test "only one deployment may be active across repositories" do
    first = deployable_repository()
    second = deployable_repository()

    assert {:ok, _deployment} = Deployments.request(first, "andreas")
    assert {:error, :deployment_already_requested} = Deployments.request(second, "andreas")
  end

  test "update status compares the running release with default branch" do
    repository = deployable_repository()

    status = Deployments.update_status(repository, String.duplicate("b", 40))
    assert status.update_available?
    refute status.current?

    current = Deployments.update_status(repository, String.duplicate("a", 40))
    assert current.current?
    refute current.update_available?
  end

  defp deployable_repository do
    suffix = System.unique_integer([:positive, :monotonic])
    owner = "deploy-owner-#{suffix}"
    name = "deploy-repo-#{suffix}"
    path = Path.join(System.tmp_dir!(), "#{owner}-#{name}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    File.write!(
      Path.join(path, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: ./scripts/ptc/bootstrap
        timeout_minutes: 10
      deployment:
        command: ./scripts/ptc/deploy
        timeout_minutes: 20
      """
    )

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["remote", "add", "origin", "git@github.com:#{owner}/#{name}.git"])
    git!(path, ["add", ".ptc-manager.yml"])
    git!(path, ["commit", "-m", "add deployment contract"])

    repository_fixture(%{github_owner: owner, github_name: name, local_path: path, enabled: true})
  end

  defp git!(path, args) do
    {_output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    :ok
  end
end
