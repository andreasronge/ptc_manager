defmodule PtcManager.DeploymentCanaryTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.DeploymentCanary
  alias PtcManager.OperationalMode
  alias PtcManager.Operations.{AgentRun, Proposal}
  alias PtcManager.Repo

  defmodule PassingAdapter do
    def analyze(_issue) do
      {:ok,
       %{
         plain_summary: "The canary read one issue and produced a private summary.",
         why_it_matters: "This proves the deployed read-only adapter can persist its result.",
         scope: "small",
         risk: "low",
         readiness: "ready",
         technical_evidence: "The deterministic canary adapter completed."
       }}
    end
  end

  defmodule FailingAdapter do
    def analyze(_issue), do: {:error, :adapter_unavailable}
  end

  setup do
    previous = Application.get_env(:ptc_manager, :operational_mode)
    Application.put_env(:ptc_manager, :operational_mode, :maintenance)
    on_exit(fn -> restore_env(:operational_mode, previous) end)
    :ok
  end

  test "runs exactly the admitted read-only invocation and activates ordinary work" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    worker_fixture(%{status: "online"})

    assert {:ok, summary} = DeploymentCanary.run("release-123", adapter: PassingAdapter)

    assert summary.issue_id == issue.id
    assert OperationalMode.mode() == {:canary, "release-123"}
    assert Repo.get!(Proposal, summary.proposal_id).issue_id == issue.id

    run = Repo.get!(AgentRun, summary.run_id)
    assert run.state == "done"
    assert run.external_key == "deployment-canary:release-123"
    assert run.status_text == "Read-only deployment canary passed."

    assert :ok = DeploymentCanary.activate("release-123", wake: fn -> :ok end)
    assert OperationalMode.mode() == :active
  end

  test "a canary that is not admitted is refused without changing the mode" do
    Application.put_env(:ptc_manager, :operational_mode, :active)
    repository = repository_fixture()
    issue_fixture(repository)
    worker_fixture(%{status: "online"})

    assert {:error, :canary_already_admitted} =
             DeploymentCanary.run("release-stray", adapter: PassingAdapter)

    assert OperationalMode.mode() == :active
    assert is_nil(PtcManager.OperationalMode.Audit.last_transition())
    refute Repo.get_by(AgentRun, external_key: "deployment-canary:release-stray")
  end

  test "fails closed and retains a visible failed run" do
    repository = repository_fixture()
    issue_fixture(repository)
    worker_fixture(%{status: "online"})

    assert {:error, :adapter_unavailable} =
             DeploymentCanary.run("release-456", adapter: FailingAdapter)

    assert OperationalMode.mode() == :maintenance

    assert %{actor: "canary", details: %{"previous" => "canary", "next" => "maintenance"}} =
             PtcManager.OperationalMode.Audit.last_transition()

    run = Repo.get_by!(AgentRun, external_key: "deployment-canary:release-456")
    assert run.state == "failed"
    assert run.status_text =~ "adapter_unavailable"
  end

  test "an abandoned canary is replaced and its run closed" do
    repository = repository_fixture()
    issue_fixture(repository)
    worker_fixture(%{status: "online"})

    assert {:error, :canary_not_stale} = DeploymentCanary.replace_stale("andreas")

    # A canary killed halfway: its claim names a process that is gone and its
    # run never finished.
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    Application.put_env(
      :ptc_manager,
      :operational_mode,
      {:canary, "release-abandoned", {:consumed, dead}}
    )

    {:ok, _run} =
      PtcManager.Operations.create_agent_run(%{
        worker_id: Repo.one!(PtcManager.Operations.Worker).id,
        role: "manager",
        state: "working",
        external_key: "deployment-canary:release-abandoned",
        started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })

    assert OperationalMode.stale_canary?()
    assert {:ok, "release-abandoned"} = DeploymentCanary.replace_stale("andreas")
    assert OperationalMode.mode() == :maintenance

    run = Repo.get_by!(AgentRun, external_key: "deployment-canary:release-abandoned")
    assert run.state == "failed"
    assert run.status_text =~ "abandoned"
  end

  test "the default canary does not depend on an external agent" do
    repository = repository_fixture()
    issue_fixture(repository)
    worker_fixture(%{status: "online"})

    assert {:ok, summary} = DeploymentCanary.run("release-no-codex")
    assert Repo.get!(Proposal, summary.proposal_id).plain_summary =~ "Deployment canary"
    assert OperationalMode.mode() == {:canary, "release-no-codex"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
