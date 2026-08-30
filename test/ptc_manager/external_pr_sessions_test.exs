defmodule PtcManager.ExternalPrSessionsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.ExternalPrSessions
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, PrPublication}
  alias PtcManager.Repo

  defmodule FakeHerdr do
    def remove_action_workspace(workspace) do
      send(Process.get(:external_session_test_pid), {:removed_workspace, workspace})
      :ok
    end
  end

  setup do
    Process.put(:external_session_test_pid, self())
    :ok
  end

  test "removes a retained repair workspace only after GitHub reports the PR terminal" do
    repository = repository_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    publication =
      %PrPublication{}
      |> PrPublication.changeset(%{
        repository_id: repository.id,
        state: "published",
        idempotency_key: String.duplicate("a", 64),
        fencing_token: 0,
        branch_name: "external/fix-42",
        base_sha: String.duplicate("b", 40),
        head_sha: String.duplicate("c", 40),
        diff_digest: String.duplicate("d", 64),
        attempt_count: 1,
        pr_number: 42,
        pr_url: "https://github.com/example/repo/pull/42",
        title: "Repair this pull request",
        remote_head_sha: String.duplicate("c", 40),
        remote_base_sha: String.duplicate("b", 40),
        head_ref: "external/fix-42",
        head_repository: "example/repo",
        published_at: now,
        pr_state: "open",
        pr_checked_at: now,
        source: "external"
      })
      |> Repo.insert!()

    action =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "repair_and_merge_pr",
        target_type: "pull_request",
        target_id: publication.id,
        target_label: "example/repo#42",
        prompt_version: 1,
        prompt: "Fix and merge pull request #42",
        baseline_issue_numbers: %{"numbers" => []},
        target_snapshot: %{},
        actor: "maintainer",
        state: "done",
        attempt_count: 1,
        requested_at: now,
        started_at: now,
        ended_at: now
      })
      |> Repo.insert!()

    worker = worker_fixture(%{worker_key: "herdr:external-cleanup"})

    {:ok, run} =
      Operations.create_agent_run(%{
        worker_id: worker.id,
        agent_action_id: action.id,
        role: "implementer",
        state: "waiting",
        status_text: "Waiting for the pull request to close.",
        agent_name: "merge_pr42_a#{action.id}_f1",
        herdr_workspace: "external-pr-42",
        herdr_pane: "external-pr-42:p1",
        herdr_session: "default",
        external_key: "default:external-pr-42:p1",
        started_at: now,
        last_heartbeat_at: now
      })

    assert {:ok, :empty} = ExternalPrSessions.cleanup_terminal_once(FakeHerdr)
    refute_receive {:removed_workspace, _workspace}

    publication
    |> PrPublication.changeset(%{pr_state: "merged", merged_at: now})
    |> Repo.update!()

    assert {:ok, cleaned} = ExternalPrSessions.cleanup_terminal_once(FakeHerdr)
    assert cleaned.id == run.id
    assert cleaned.state == "done"
    assert cleaned.herdr_workspace == nil
    assert cleaned.ended_at
    assert_receive {:removed_workspace, "external-pr-42"}
  end
end
