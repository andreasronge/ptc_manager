defmodule PtcManager.Machine.GateTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Machine.{Gate, Inventory}
  alias PtcManager.{Operations, Stalls}
  alias PtcManager.Operations.{AgentAction, Job}

  setup do
    on_exit(fn -> Inventory.clear() end)
    :ok
  end

  defp gated_repository do
    repository = repository_fixture()

    {:ok, repository} =
      Operations.update_machine_requirements(
        repository.id,
        %{"tools" => [%{"name" => "docker-daemon"}]},
        "maintainer"
      )

    repository
  end

  defp queued_action!(repository, requested_at \\ DateTime.utc_now()) do
    requested_at = DateTime.truncate(requested_at, :microsecond)

    %AgentAction{}
    |> AgentAction.changeset(%{
      repository_id: repository.id,
      action_key: "issue_analysis",
      target_type: "issue",
      target_id: System.unique_integer([:positive]),
      target_label: "#{repository.github_name}#1",
      prompt_version: 1,
      prompt: "Analyse the issue",
      baseline_issue_numbers: %{"numbers" => []},
      target_snapshot: %{},
      actor: "maintainer",
      state: "queued",
      attempt_count: 0,
      requested_at: requested_at
    })
    |> Repo.insert!()
  end

  test "only repositories with unmet requirements are unsatisfied" do
    gated = gated_repository()
    free = repository_fixture()

    assert Gate.unsatisfied_repository_ids() == [gated.id]
    assert Gate.check(gated.id) == {:error, :machine_incapable}
    assert Gate.check(free) == :ok
    assert Map.keys(Gate.evaluations()) == [gated.id]
  end

  test "an action for an incapable repository waits without holding up others" do
    gated = gated_repository()
    free = repository_fixture()
    waiting = queued_action!(gated, DateTime.add(DateTime.utc_now(), -60, :second))
    other = queued_action!(free)

    assert Operations.next_agent_action_candidate_for_lane(:any).id == other.id
    assert {:error, :machine_incapable} = Operations.claim_agent_action(waiting.id)
    assert Repo.get!(AgentAction, waiting.id).state == "queued"
  end

  test "resuming retained work is refused on an incapable machine" do
    repository = gated_repository()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 2, "standard")

    job =
      job
      |> Job.changeset(%{state: "failed", fencing_token: 1, branch_name: "resume-test"})
      |> Repo.update!()

    assert {:error, :machine_incapable} = Operations.resume_from_worktree(job.id, "maintainer")
  end

  test "work waiting for a capable machine becomes a stall after the queue wait" do
    repository = gated_repository()
    action = queued_action!(repository)
    past = DateTime.add(DateTime.utc_now(), -3_600, :second)

    action |> Ecto.Changeset.change(updated_at: past) |> Repo.update!()

    assert [stall] = Stalls.machine_incapable(DateTime.utc_now())
    assert stall.kind == :machine_incapable
    assert stall.target_type == "agent_action" and stall.target_id == action.id
    assert stall.detail =~ "docker-daemon not probed yet (pane, setup)"

    assert Stalls.machine_incapable(DateTime.add(past, 60, :second)) == []
  end
end
