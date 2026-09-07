defmodule PtcManagerWeb.ExecutionProfilesLiveTest do
  use PtcManagerWeb.ConnCase, async: false
  alias PtcManager.{Operations, Repo}
  alias PtcManager.Operations.Job

  defmodule Catalog do
    def models(kind),
      do: {:ok, %{"kind" => kind, "models" => [%{"id" => "test-model", "name" => "Test model"}]}}
  end

  defmodule Snapshot do
    def capture(_job),
      do:
        {:ok,
         %{
           "head_sha" => String.duplicate("a", 40),
           "base_sha" => String.duplicate("b", 40),
           "diff_digest" => String.duplicate("c", 64)
         }}
  end

  defp login(conn), do: init_test_session(conn, %{authenticated: true, actor: "maintainer"})

  test "edits presets and discovers models without altering already-approved jobs", %{conn: conn} do
    old = Application.get_env(:ptc_manager, :review_adapter)
    Application.put_env(:ptc_manager, :review_adapter, Catalog)

    on_exit(fn ->
      if old,
        do: Application.put_env(:ptc_manager, :review_adapter, old),
        else: Application.delete_env(:ptc_manager, :review_adapter)
    end)

    {:ok, view, html} = conn |> login() |> live("/execution-profiles")
    assert html =~ "Execution profiles"

    view
    |> form("#profile-strong",
      profile: %{model: "strong-model", max_reviews: "5", review_timeout_minutes: "25"}
    )
    |> render_submit()

    assert render(view) =~ "Existing jobs keep their approved settings"

    assert Repo.get_by!(PtcManager.ExecutionProfiles.Profile, name: "strong").review_timeout_ms ==
             1_500_000

    view |> element("button", "Refresh available models") |> render_click()
    assert render_async(view) =~ "test-model"
  end

  test "shows preserved findings and records explicit additional review budget", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 1, "small")

    job
    |> Job.changeset(%{state: "working", review_state: "paused", branch_name: "keep-my-work"})
    |> Repo.update!()

    {:ok, view, html} = conn |> login() |> live("/jobs/#{job.id}/reviews")
    assert html =~ "Work preserved"
    assert html =~ "keep-my-work"

    view
    |> form("#review-decision",
      decision: %{
        generation: "0",
        extra_rounds: "2",
        profile: "strong",
        instructions: "Inspect all failure paths before editing.",
        reason: ""
      }
    )
    |> render_submit(%{"decision" => %{"action" => "continue"}})

    updated = Repo.get!(Job, job.id)
    assert updated.review_continuation_instructions == "Inspect all failure paths before editing."
    assert render(view) =~ "Inspect all failure paths before editing."
    assert updated.required_review_count == 3
    assert updated.review_state == "resume_pending"
    assert updated.branch_name == "keep-my-work"
  end

  test "review failures are separate from completed budget and can continue without extra rounds",
       %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 1, "small")
    job = job |> Job.changeset(%{state: "working", fencing_token: 1}) |> Repo.update!()
    {:ok, round} = PtcManager.Reviews.request(job.id, 1, "timeout", snapshot: Snapshot)
    PtcManager.Reviews.fail(round.id, :review_timeout)
    {:ok, view, html} = conn |> login() |> live("/jobs/#{job.id}/reviews")
    assert html =~ "0 of 1 completed reviews"
    assert html =~ "1 failed attempts"
    assert html =~ "Review attempt failed"
    assert html =~ "15 minutes"
    assert has_element?(view, "#review-round-#{round.id}", "Attempt 1 · failed")
    assert has_element?(view, "option[value='0'][selected]")

    view
    |> form("#review-decision", decision: %{generation: "0", extra_rounds: "0"})
    |> render_submit(%{"decision" => %{"action" => "continue"}})

    assert Repo.get!(Job, job.id).required_review_count == 1
    assert Repo.get!(Job, job.id).review_state == "resume_pending"
  end

  test "handoff expansion survives operation updates and round completion", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 1, "small")
    job = job |> Job.changeset(%{state: "working", fencing_token: 1}) |> Repo.update!()

    {:ok, round} =
      PtcManager.Reviews.request(job.id, 1, "handoff",
        snapshot: Snapshot,
        handoff: "Validated the new behavior."
      )

    {:ok, view, _} = conn |> login() |> live("/jobs/#{job.id}/reviews")
    toggle = "#handoff-toggle-#{round.id}"
    body = "#handoff-body-#{round.id}"
    view |> element(toggle) |> render_click()
    assert has_element?(view, toggle <> "[aria-expanded=true]")
    assert has_element?(view, body, "Validated the new behavior.")
    Operations.notify_changed(:test)
    assert has_element?(view, body)
    PtcManager.Reviews.fail(round.id, :review_timeout)
    assert has_element?(view, "#review-round-#{round.id}", "failed")
    assert has_element?(view, body)
    view |> element(toggle) |> render_click()
    Operations.notify_changed(:test)
    refute has_element?(view, body)
  end

  test "cancellation requires a reason and posting an explanation is a separate approval", %{
    conn: conn
  } do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 1, "small")
    job |> Job.changeset(%{state: "working", review_state: "paused"}) |> Repo.update!()
    {:ok, view, _} = conn |> login() |> live("/jobs/#{job.id}/reviews")

    view
    |> form("#review-decision",
      decision: %{
        generation: "0",
        extra_rounds: "0",
        reason: "Choose a smaller change"
      }
    )
    |> render_submit(%{"decision" => %{"action" => "cancel"}})

    assert Repo.get!(Job, job.id).state == "cancelled"
    assert is_nil(Repo.get!(Job, job.id).cancellation_action_id)
    assert has_element?(view, "#cancellation-note", "Approve and post explanation")

    view
    |> form("#cancellation-note",
      note: %{body: "We cancelled this attempt and preserved the work."}
    )
    |> render_submit()

    action_id = Repo.get!(Job, job.id).cancellation_action_id
    assert is_integer(action_id)
    action = Repo.get!(PtcManager.Operations.AgentAction, action_id)
    assert action.action_key == "post_cancellation_note"

    assert action.target_snapshot["approved_comment"] ==
             "We cancelled this attempt and preserved the work."

    assert action.state == "queued"
  end
end
