defmodule PtcManagerWeb.ExecutionProfilesLiveTest do
  use PtcManagerWeb.ConnCase, async: false
  alias PtcManager.{Operations, Repo}
  alias PtcManager.Operations.Job

  defmodule Catalog do
    def models(kind),
      do: {:ok, %{"kind" => kind, "models" => [%{"id" => "test-model", "name" => "Test model"}]}}
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
    |> form("#profile-strong", profile: %{model: "strong-model", max_reviews: "5"})
    |> render_submit()

    assert render(view) =~ "Existing jobs keep their approved settings"
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
        reason: ""
      }
    )
    |> render_submit(%{"decision" => %{"action" => "continue"}})

    updated = Repo.get!(Job, job.id)
    assert updated.required_review_count == 3
    assert updated.review_state == "resume_pending"
    assert updated.branch_name == "keep-my-work"
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
