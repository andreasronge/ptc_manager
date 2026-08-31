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

  test "fails closed and retains a visible failed run" do
    repository = repository_fixture()
    issue_fixture(repository)
    worker_fixture(%{status: "online"})

    assert {:error, :adapter_unavailable} =
             DeploymentCanary.run("release-456", adapter: FailingAdapter)

    assert OperationalMode.mode() == :maintenance

    run = Repo.get_by!(AgentRun, external_key: "deployment-canary:release-456")
    assert run.state == "failed"
    assert run.status_text =~ "adapter_unavailable"
  end

  test "the default canary does not depend on the optional Codex manager flag" do
    repository = repository_fixture()
    issue_fixture(repository)
    worker_fixture(%{status: "online"})
    previous = Application.get_env(:ptc_manager, :manager_enabled)
    Application.put_env(:ptc_manager, :manager_enabled, false)
    on_exit(fn -> restore_env(:manager_enabled, previous) end)

    assert {:ok, summary} = DeploymentCanary.run("release-no-codex")
    assert Repo.get!(Proposal, summary.proposal_id).plain_summary =~ "Deployment canary"
    assert OperationalMode.mode() == {:canary, "release-no-codex"}
  end

  test "ordinary direct manager work is rejected while maintenance is active" do
    repository = repository_fixture()
    issue = issue_fixture(repository)

    assert {:error, :maintenance_mode} =
             PtcManager.Manager.investigate_issue(issue.id, adapter: PassingAdapter)

    refute Repo.exists?(Proposal)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
