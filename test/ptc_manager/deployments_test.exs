defmodule PtcManager.DeploymentsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Deployments
  alias PtcManager.Deployments.Deployment
  alias PtcManager.Operations.{AgentAction, AgentRun, AuditEvent}
  alias PtcManager.Repository.GitProbe
  alias PtcManager.{OperationalMode, Repo}

  defmodule RevisionSource do
    def latest(repository) do
      {sha, 0} =
        System.cmd("git", ["-C", repository.local_path, "rev-parse", "HEAD"],
          stderr_to_stdout: true
        )

      {:ok, String.trim(sha)}
    end
  end

  defmodule Runner do
    def start(deployment, contract) do
      send(
        Application.fetch_env!(:ptc_manager, :deployment_test_pid),
        {:deployment_started, deployment, contract}
      )

      :ok
    end

    def status(deployment) do
      case Application.get_env(:ptc_manager, :deployment_test_runner_status, :inactive) do
        callback when is_function(callback, 1) -> callback.(deployment)
        status -> status
      end
    end

    def cleanup(deployment) do
      send(
        Application.fetch_env!(:ptc_manager, :deployment_test_pid),
        {:deployment_cleanup, deployment.id}
      )

      :ok
    end
  end

  setup do
    previous =
      Map.new(
        [
          :deployment_revision_source,
          :deployment_runner,
          :deployment_spool_path,
          :deployed_sha,
          :checkout_probe,
          :deployment_start_timeout_ms,
          :deployment_completion_grace_ms,
          :deployment_test_runner_status
        ],
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
    Application.put_env(:ptc_manager, :deployed_sha, String.duplicate("a", 40))
    Application.put_env(:ptc_manager, :checkout_probe, GitProbe)
    Application.put_env(:ptc_manager, :deployment_start_timeout_ms, 60_000)
    Application.put_env(:ptc_manager, :deployment_completion_grace_ms, 60_000)
    Application.put_env(:ptc_manager, :deployment_test_runner_status, :inactive)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)

      Application.delete_env(:ptc_manager, :deployment_test_pid)
      if OperationalMode.mode() == :draining, do: OperationalMode.leave_draining()
      File.rm_rf!(spool)
    end)

    %{spool: spool}
  end

  test "deployment drains new work, names what holds it, and launches once that work finishes" do
    repository = deployable_repository()
    worker = worker_fixture()

    run = agent_run!(worker, %{state: "working", agent_name: "impl_j7_f1"})
    # A retained implementer sitting on a prompt for an open PR is nobody's work.
    agent_run!(worker, %{state: "blocked", agent_name: "impl_j25_f1"})
    # A stale record of an action that already finished is not work either.
    agent_run!(worker, %{state: "unknown", agent_action_id: action!(repository, "done").id})
    guarded_action = action!(repository, "running")

    agent_run!(worker, %{
      state: "blocked",
      agent_name: "repair_pr9_a#{guarded_action.id}_f1",
      agent_action_id: guarded_action.id
    })

    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert deployment.state == "draining"
    assert OperationalMode.mode() == :draining
    refute_receive {:deployment_started, _, _}, 100

    assert Deployments.advance() == :ok
    refute_receive {:deployment_started, _, _}, 100
    waiting = Repo.get!(Deployment, deployment.id)
    assert waiting.status_text =~ "Waiting for 2 managed agents"
    assert waiting.status_text =~ "impl_j7_f1 (working, started"
    assert waiting.status_text =~ "repair_pr9_a#{guarded_action.id}_f1 (blocked, started"
    refute waiting.status_text =~ "impl_j25_f1"

    run |> AgentRun.changeset(%{state: "done", ended_at: now()}) |> Repo.update!()
    guarded_action |> AgentAction.changeset(%{state: "done", ended_at: now()}) |> Repo.update!()

    assert Deployments.advance() == :ok
    assert_receive {:deployment_started, started, contract}
    assert started.requested_sha == deployment.requested_sha
    assert contract.deployment_command == "./scripts/ptc/deploy"
    assert Repo.get!(Deployment, deployment.id).state == "running"
  end

  test "a waiting deployment fails as soon as the default branch moves on" do
    repository = deployable_repository()
    agent_run!(worker_fixture(), %{state: "working"})
    assert {:ok, deployment} = Deployments.request(repository, "andreas")

    File.write!(Path.join(repository.local_path, "CHANGE.md"), "main moved on\n")
    git!(repository.local_path, ["add", "CHANGE.md"])
    git!(repository.local_path, ["commit", "-m", "move main"])

    assert Deployments.advance() == :ok
    assert Repo.get!(Deployment, deployment.id).state == "draining"

    assert Deployments.advance(check_head?: true) == :ok
    failed = Repo.get!(Deployment, deployment.id)
    assert failed.state == "failed"
    assert failed.status_text =~ "main moved to"
    assert failed.status_text =~ "Request it again"
    assert failed.last_error =~ "no longer the default-branch head"
    assert OperationalMode.mode() == :active
    refute_receive {:deployment_started, _, _}, 100
  end

  test "a waiting deployment can be cancelled until the host runner starts" do
    repository = deployable_repository()
    agent_run!(worker_fixture(), %{state: "working"})
    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert OperationalMode.mode() == :draining

    assert {:ok, %Deployment{state: "cancelled"} = cancelled} =
             Deployments.cancel(deployment.id, "andreas")

    assert cancelled.status_text =~ "Cancelled by andreas"
    assert OperationalMode.mode() == :active
    assert Repo.get_by!(AuditEvent, action: "deployment.cancelled").target_id == deployment.id
    assert {:error, :deployment_not_cancellable} = Deployments.cancel(deployment.id, "andreas")
    assert Deployments.advance() == :idle
    refute_receive {:deployment_started, _, _}, 100
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

  test "deployment freezes its command from the requested commit while waiting to drain" do
    repository = deployable_repository()
    worker = worker_fixture()
    current = now()

    %AgentRun{}
    |> AgentRun.changeset(%{
      worker_id: worker.id,
      role: "implementer",
      state: "working",
      started_at: current,
      last_heartbeat_at: current
    })
    |> Repo.insert!()

    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert deployment.deployment_command == "./scripts/ptc/deploy"
    File.write!(Path.join(repository.local_path, ".ptc-manager.yml"), contract("./wrong-command"))

    Repo.update_all(AgentRun, set: [state: "done", ended_at: current])
    assert :ok = Deployments.advance()
    assert_receive {:deployment_started, _, frozen}
    assert frozen.deployment_command == "./scripts/ptc/deploy"
  end

  test "active deployment restores drain mode after a coordinator restart" do
    repository = deployable_repository()
    assert {:ok, _deployment} = Deployments.request(repository, "andreas")
    assert :ok = Deployments.advance()
    assert_receive {:deployment_started, _, _}

    assert :ok = OperationalMode.leave_draining()
    assert OperationalMode.mode() == :active
    assert :ok = Deployments.advance()
    assert OperationalMode.mode() == :draining
  end

  test "a deployment without a host status reaches a bounded terminal failure" do
    repository = deployable_repository()
    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert :ok = Deployments.advance()
    assert_receive {:deployment_started, _, _}

    stale = DateTime.add(now(), -25, :minute)

    deployment
    |> Repo.reload!()
    |> Deployment.changeset(%{started_at: stale})
    |> Repo.update!()

    Application.put_env(:ptc_manager, :deployment_completion_grace_ms, 0)
    assert :idle = Deployments.advance()
    failed = Repo.get!(Deployment, deployment.id)
    assert failed.state == "failed"
    assert failed.last_error =~ "deployment_status_timeout"
    assert_receive {:deployment_cleanup, deployment_id}
    assert deployment_id == deployment.id
    assert OperationalMode.mode() == :active
  end

  test "an active host runner is not failed when its status handoff is late" do
    repository = deployable_repository()
    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert :ok = Deployments.advance()
    assert_receive {:deployment_started, _, _}

    stale = DateTime.add(now(), -25, :minute)

    deployment
    |> Repo.reload!()
    |> Deployment.changeset(%{started_at: stale})
    |> Repo.update!()

    Application.put_env(:ptc_manager, :deployment_completion_grace_ms, 0)
    Application.put_env(:ptc_manager, :deployment_test_runner_status, :active)
    assert :ok = Deployments.advance()
    assert Repo.get!(Deployment, deployment.id).state == "running"
    refute_receive {:deployment_cleanup, _}
    assert OperationalMode.mode() == :draining
  end

  test "an inactive runner's newly written terminal status wins the timeout race", %{spool: spool} do
    repository = deployable_repository()
    assert {:ok, deployment} = Deployments.request(repository, "andreas")
    assert :ok = Deployments.advance()
    assert_receive {:deployment_started, _, _}

    stale = DateTime.add(now(), -25, :minute)

    deployment
    |> Repo.reload!()
    |> Deployment.changeset(%{started_at: stale})
    |> Repo.update!()

    Application.put_env(:ptc_manager, :deployment_completion_grace_ms, 0)

    Application.put_env(:ptc_manager, :deployment_test_runner_status, fn current ->
      File.mkdir_p!(spool)

      File.write!(
        Path.join(spool, "deployment-#{current.id}.status.json"),
        Jason.encode!(%{
          "deployment_id" => current.id,
          "requested_sha" => current.requested_sha,
          "state" => "completed",
          "release_id" => "race-complete",
          "status_text" => "Completed while status was being reconciled.",
          "error" => nil
        })
      )

      :inactive
    end)

    assert :idle = Deployments.advance()
    completed = Repo.get!(Deployment, deployment.id)
    assert completed.state == "completed"
    assert completed.release_id == "race-complete"
    refute_receive {:deployment_cleanup, _}
    assert OperationalMode.mode() == :active
  end

  test "a legacy active deployment without a frozen contract can ingest terminal status", %{
    spool: spool
  } do
    repository = deployable_repository()
    requested_sha = String.duplicate("b", 40)
    current = now()

    {1, [legacy]} =
      Repo.insert_all(
        Deployment,
        [
          %{
            repository_id: repository.id,
            requested_sha: requested_sha,
            state: "running",
            requested_by: "previous-release",
            requested_at: current,
            started_at: current,
            inserted_at: current,
            updated_at: current
          }
        ],
        returning: true
      )

    File.mkdir_p!(spool)

    File.write!(
      Path.join(spool, "deployment-#{legacy.id}.status.json"),
      Jason.encode!(%{
        "deployment_id" => legacy.id,
        "requested_sha" => requested_sha,
        "state" => "completed",
        "release_id" => "legacy-complete",
        "status_text" => "Previous host runner completed.",
        "error" => nil
      })
    )

    assert :idle = Deployments.advance()
    completed = Repo.get!(Deployment, legacy.id)
    assert completed.state == "completed"
    assert completed.release_id == "legacy-complete"
    assert is_nil(completed.deployment_command)
    assert OperationalMode.mode() == :active
  end

  defp deployable_repository do
    suffix = System.unique_integer([:positive, :monotonic])
    owner = "deploy-owner-#{suffix}"
    name = "deploy-repo-#{suffix}"
    path = Path.join(System.tmp_dir!(), "#{owner}-#{name}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    File.write!(Path.join(path, ".ptc-manager.yml"), contract("./scripts/ptc/deploy"))

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["remote", "add", "origin", "git@github.com:#{owner}/#{name}.git"])
    git!(path, ["add", ".ptc-manager.yml"])
    git!(path, ["commit", "-m", "add deployment contract"])

    repository_fixture(%{github_owner: owner, github_name: name, local_path: path, enabled: true})
  end

  defp agent_run!(worker, attrs) do
    now = now()

    %AgentRun{}
    |> AgentRun.changeset(
      Map.merge(
        %{worker_id: worker.id, role: "implementer", started_at: now, last_heartbeat_at: now},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp action!(repository, state) do
    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "repair_pr",
      target_type: "pull_request",
      target_id: 9,
      target_label: "example/repo#9",
      prompt: "Repair PR 9",
      actor: "maintainer",
      state: state,
      attempt_count: 1,
      requested_at: now()
    })
    |> Repo.insert!()
  end

  defp contract(command) do
    """
    version: 1
    bootstrap:
      command: ./scripts/ptc/bootstrap
      timeout_minutes: 10
    deployment:
      command: #{command}
      timeout_minutes: 20
    """
  end

  defp git!(path, args) do
    {_output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    :ok
  end
end
