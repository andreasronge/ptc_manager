defmodule PtcManager.ReviewsTest do
  use PtcManager.DataCase, async: false
  import PtcManager.OperationsFixtures
  alias PtcManager.{Operations, Repo, Reviews, ExecutionProfiles}
  alias PtcManager.Operations.Job

  defmodule Snapshot do
    def capture(_job) do
      head = Process.get(:review_test_head, String.duplicate("a", 40))

      {:ok,
       %{
         "head_sha" => head,
         "base_sha" => String.duplicate("b", 40),
         "diff_digest" => String.duplicate("c", 64),
         "diff" => "a bounded patch",
         "issue" => "Fix it",
         "requirements" => Process.get(:review_test_requirements, "Original requirements")
       }}
    end
  end

  defmodule FailedSnapshot do
    def capture(_), do: {:error, :git_output_too_large}
  end

  defmodule LateFailingSnapshot do
    def capture(job) do
      round = List.last(Reviews.rounds(job.id))
      {:ok, _} = Reviews.prepare_pending(round.id, snapshot: Snapshot)
      {:ok, _} = Reviews.claim(round.id)
      {:error, :late_capture_failure}
    end
  end

  test "plain handoff survives a failed attempt and continuation retains useful review" do
    job = job!(3)
    note = "Kept the existing locking strategy. Added a concurrent-writer regression."
    {:ok, round} = Reviews.request(job.id, 1, "handoff", snapshot: Snapshot, handoff: note)
    assert round.input["handoff"] == note
    {:ok, _} = Reviews.claim(round.id)
    {:ok, _} = Reviews.complete(round.id, findings())
    Process.put(:review_test_head, String.duplicate("d", 40))
    {:ok, failed} = request(job, "failed-followup")
    Reviews.fail(failed.id, :review_timeout)
    text = PtcManager.Reviews.Context.handoff(job.id)
    assert text =~ "Fix the race"
    assert text =~ note
    assert text =~ round.head_sha
    assert text =~ "review_timeout"
  end

  test "advisory findings pass the review instead of spending another round" do
    job = job!(1)
    {:ok, round} = request(job, "advisory")
    {:ok, _} = Reviews.claim(round.id)
    {:ok, _} = Reviews.complete(round.id, advisory())
    completed = Repo.get!(PtcManager.Reviews.Round, round.id)
    assert completed.state == "completed"
    assert Reviews.outcome(completed.result) == "passed"

    saved = Repo.get!(Job, job.id)
    assert saved.review_state == "passed"
    assert saved.reviewed_head_sha == round.head_sha
    assert is_nil(saved.last_error)

    text = PtcManager.Reviews.Context.handoff(job.id)
    assert text =~ "(passed)"
    assert text =~ "low: Two collections can record the same whole second."
  end

  test "a medium finding still withholds the pass and pauses an exhausted budget" do
    job = job!(1)
    {:ok, round} = request(job, "blocking")
    {:ok, _} = Reviews.claim(round.id)

    {:ok, _} =
      Reviews.complete(round.id, %{
        "summary" => "One boundary is unguarded.",
        "findings" => [
          %{"severity" => "medium", "description" => "Invalid evidence crashes cleanup."},
          %{
            "severity" => "low",
            "description" => "Two collections can record the same whole second."
          }
        ]
      })

    assert Reviews.outcome(Repo.get!(PtcManager.Reviews.Round, round.id).result) ==
             "changes_requested"

    saved = Repo.get!(Job, job.id)
    assert saved.review_state == "paused"
    assert is_nil(saved.reviewed_head_sha)
  end

  test "the reviewed commit advances only with an assessment of this attempt" do
    job = job!(3)
    assert is_nil(reviewed_head(job))

    {:ok, first} = request(job, "first-assessment")
    {:ok, _} = Reviews.claim(first.id)
    assert is_nil(reviewed_head(job))
    {:ok, _} = Reviews.complete(first.id, findings())
    assert reviewed_head(job) == first.head_sha

    Process.put(:review_test_head, String.duplicate("d", 40))
    {:ok, failed} = request(job, "failed-attempt")
    Reviews.fail(failed.id, :review_timeout)
    assert reviewed_head(job) == first.head_sha

    restarted = job |> Job.changeset(%{fencing_token: 2}) |> Repo.update!()
    assert is_nil(reviewed_head(restarted))
  end

  test "moved requirements leave the whole change to review again" do
    job = job!(3)
    {:ok, first} = request(job, "assessment-under-original")
    {:ok, _} = Reviews.claim(first.id)
    {:ok, _} = Reviews.complete(first.id, findings())

    assert Reviews.last_reviewed_head(job, "Fix it", "Original requirements") == %{
             head_sha: first.head_sha,
             base_sha: first.base_sha
           }

    # The earlier commits were never assessed against the changed requirement.
    assert is_nil(Reviews.last_reviewed_head(job, "Fix it", "Changed linked requirement"))
    assert is_nil(Reviews.last_reviewed_head(job, "A reframed issue", "Original requirements"))
  end

  test "advisory findings of a passing assessment reach the pull request" do
    job = job!(2)
    {:ok, round} = request(job, "advisory-publication")
    {:ok, _} = Reviews.claim(round.id)
    {:ok, _} = Reviews.complete(round.id, advisory())

    assert [%{"description" => description}] =
             Reviews.advisory_findings(job.id, round.head_sha)

    assert description == "Two collections can record the same whole second."
    assert Reviews.advisory_findings(job.id, String.duplicate("f", 40)) == []

    body = PtcManager.GitHub.AppBroker.pull_request_body(42, "none", advisory()["findings"])
    assert body =~ "## Advisory review findings"
    assert body =~ "- Two collections can record the same whole second."
    assert body =~ "complete assessment is in the PtcManager review history"
    assert PtcManager.GitHub.AppBroker.pull_request_body(42, "none") =~ "## Agent retrospective"
    refute PtcManager.GitHub.AppBroker.pull_request_body(42, "none") =~ "Advisory"

    # Merging the publication must close its issue so a dependent issue can
    # start; only the body's own closing line may say so.
    assert String.starts_with?(body, "Closes #42.\n")
    assert PtcManager.GitHub.LinkedIssues.from_body(body, "owner/repo") == [42]
  end

  test "reviewer text reaches the pull request as data, never as markup" do
    findings =
      [
        %{
          "severity" => "low",
          "description" =>
            "Closes #39 and thanks @maintainer.\n\n## Injected heading\n\n<details>hidden</details>"
        }
      ] ++
        for(
          index <- 1..12,
          do: %{"severity" => "low", "description" => "Filler finding #{index}"}
        )

    body = PtcManager.GitHub.AppBroker.pull_request_body(42, "none", findings)

    refute body =~ "Closes #39"
    refute body =~ "## Injected heading"
    refute body =~ "<details>"

    assert body =~
             "- Closes \\#39 and thanks \\@maintainer. \\#\\# Injected heading &lt;details>hidden&lt;/details>"

    assert body =~ "Another 3 advisory findings and the complete assessment are in"
    assert [_heading] = Regex.scan(~r/^## Advisory review findings$/m, body)

    long = [%{"severity" => "low", "description" => String.duplicate("x", 4_000)}]
    long_body = PtcManager.GitHub.AppBroker.pull_request_body(42, "none", long)
    assert long_body =~ "[Text shortened; full source remains in the review history"
    assert String.length(long_body) < 2_000
  end

  test "a blocking assessment leaves no advisory follow-up" do
    job = job!(2)
    {:ok, round} = request(job, "blocking-publication")
    {:ok, _} = Reviews.claim(round.id)

    {:ok, _} =
      Reviews.complete(round.id, %{
        "summary" => "Unsafe.",
        "findings" => [
          %{"severity" => "high", "description" => "Overwrites the new attempt."},
          %{
            "severity" => "low",
            "description" => "Two collections can record the same whole second."
          }
        ]
      })

    assert Reviews.advisory_findings(job.id, round.head_sha) == []
  end

  test "reviewer sessions stay with their job and profile across rounds" do
    job = job!(4)
    session = Ecto.UUID.generate()
    {:ok, first} = request(job, "first-session")
    assert is_nil(PtcManager.Reviews.Context.session_id(first))
    {:ok, _} = Reviews.claim(first.id)
    assert {:ok, _} = PtcManager.Reviews.Context.record_session(first, session)
    {:ok, _} = Reviews.complete(first.id, findings())
    assert {:error, :stale_review} = PtcManager.Reviews.Context.record_session(first, session)

    Process.put(:review_test_head, String.duplicate("d", 40))
    {:ok, second} = request(job, "second-session")
    assert PtcManager.Reviews.Context.session_id(second) == session
    changed = put_in(second.input["settings"]["reviewer_model"], "different-model")
    assert is_nil(PtcManager.Reviews.Context.session_id(changed))
    other = job!(2)
    {:ok, unrelated} = request(other, "unrelated")
    assert is_nil(PtcManager.Reviews.Context.session_id(unrelated))
  end

  test "handoffs are bounded and retries preserve their original note" do
    job = job!(2)

    assert {:error, :review_not_admissible} =
             Reviews.request(job.id, 1, "too-large", handoff: String.duplicate("x", 20_001))

    assert Reviews.rounds(job.id) == []

    {:ok, first} =
      Reviews.request(job.id, 1, "note", snapshot: Snapshot, handoff: "Tested the race.")

    Reviews.fail(first.id, :review_timeout)
    {:ok, pending} = Reviews.decide(job.id, 0, "retry_review", %{}, "maintainer")
    {:ok, retried} = Reviews.start_retry(pending)
    assert retried.input["handoff"] == "Tested the race."
  end

  test "large Unicode handoffs are bounded without corrupting UTF-8" do
    job = job!(2)
    {:ok, round} = request(job, "large-handoff")
    {:ok, _} = Reviews.claim(round.id)

    result = %{
      "summary" => "Review details",
      "findings" =>
        for(
          _ <- 1..30,
          do: %{"severity" => "high", "description" => String.duplicate("界", 4_000)}
        )
    }

    {:ok, _} = Reviews.complete(round.id, result)
    text = PtcManager.Reviews.Context.handoff(job.id)
    assert byte_size(text) <= 60_000
    assert String.valid?(text)
    assert text =~ "shortened"

    assert {:ok, prompt} =
             PtcManager.Reviews.Context.append_handoff(String.duplicate("p", 115_000), job.id)

    assert byte_size(prompt) <= 120_000
  end

  test "sweeper recovers a discarded continuation in the gap after stopping the old agent" do
    job = job!(2)
    job = job |> Job.changeset(%{review_state: "resume_pending"}) |> Repo.update!()
    Reviews.sweep()
    import Ecto.Query
    query = from o in Oban.Job, where: o.worker == "PtcManager.Reviews.ResumeWorker"
    assert [%{args: %{"job_id" => id}} = queued] = Repo.all(query)
    assert id == job.id
    queued |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()
    Reviews.sweep()
    assert Repo.aggregate(from(o in query, where: o.state == "available"), :count) == 1
  end

  test "changed linked requirements invalidate cached approval for the same commit" do
    job = job!(3)
    {:ok, first} = request(job, "first-context")
    {:ok, _} = Reviews.claim(first.id)
    {:ok, _} = Reviews.complete(first.id, clean())
    Process.put(:review_test_requirements, "Changed linked requirement")
    {:ok, second} = request(job, "changed-context")
    assert second.head_sha == first.head_sha
    assert second.state == "queued"
  end

  test "a late preparation failure cannot invalidate a running review" do
    job = job!(2)

    assert {:ok, round} =
             Reviews.request(job.id, 1, "overlapping-preparation", snapshot: LateFailingSnapshot)

    assert round.state == "running"
    assert Repo.get!(Job, job.id).review_state == "running"
    assert {:ok, _} = Reviews.complete(round.id, clean())
    assert Repo.get!(Job, job.id).review_state == "passed"
  end

  test "snapshot failures remain review attempts and replay does not recapture" do
    job = job!(2)
    assert {:ok, attempt} = Reviews.request(job.id, 1, "setup-failure", snapshot: FailedSnapshot)
    assert attempt.state == "failed"
    assert attempt.error =~ "git_output_too_large"
    assert Repo.get!(Job, job.id).review_state == "paused"
    assert {:ok, replay} = Reviews.request(job.id, 1, "setup-failure", snapshot: Snapshot)
    assert replay.id == attempt.id
    assert length(Reviews.rounds(job.id)) == 1
  end

  test "a lost admission response replays before inspecting a changed workspace" do
    job = job!(2)
    assert {:ok, attempt} = request(job, "lost-response")
    assert {:ok, replay} = Reviews.request(job.id, 1, "lost-response", snapshot: FailedSnapshot)
    assert replay.id == attempt.id
  end

  test "partial stopped work respects unsafe, acknowledged, and superseded outcomes" do
    job = job!(2)
    report = %{"reason_code" => "unsafe_to_proceed", "progress" => "partial"}

    failed =
      job
      |> Job.changeset(%{
        state: "failed",
        stop_report: report,
        stop_reported_at: DateTime.utc_now()
      })
      |> Repo.update!()

    refute Reviews.decision_available?(failed)

    assert {:error, :review_decision_stale} =
             Reviews.decide(job.id, 0, "continue", %{}, "maintainer")

    failed =
      failed
      |> Job.changeset(%{stop_report: %{report | "reason_code" => "environment_broken"}})
      |> Repo.update!()

    assert Reviews.decision_available?(failed)

    acknowledged =
      failed |> Job.changeset(%{stop_acknowledged_at: DateTime.utc_now()}) |> Repo.update!()

    refute Reviews.decision_available?(acknowledged)
    failed = acknowledged |> Job.changeset(%{stop_acknowledged_at: nil}) |> Repo.update!()

    %Job{}
    |> Job.changeset(%{
      repository_id: job.repository_id,
      issue_id: job.issue_id,
      approval_id: job.approval_id,
      kind: "implementation",
      state: "done",
      fencing_token: 1
    })
    |> Repo.insert!()

    refute Reviews.decision_available?(failed)
  end

  test "failed retry admission rolls back to a recoverable continuation" do
    job = job!(2)
    {:ok, round} = request(job, "failed-first")
    Reviews.fail(round.id, :review_timeout)
    {:ok, pending} = Reviews.decide(job.id, 0, "retry_review", %{}, "maintainer")

    Repo.query!(
      "CREATE TEMP TRIGGER reject_review_admission BEFORE INSERT ON review_rounds BEGIN SELECT RAISE(ABORT, 'injected admission failure'); END"
    )

    try do
      assert_raise Exqlite.Error, fn -> Reviews.start_retry(pending) end
      assert Repo.get!(Job, job.id).review_state == "resume_pending"
      assert length(Reviews.rounds(job.id)) == 1
    after
      Repo.query!("DROP TRIGGER reject_review_admission")
    end
  end

  defp job!(budget) do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", budget, "standard")

    job
    |> Job.changeset(%{state: "working", fencing_token: 1, branch_name: "review-test"})
    |> Repo.update!()
  end

  defp request(job, id), do: Reviews.request(job.id, job.fencing_token, id, snapshot: Snapshot)
  defp clean, do: %{"summary" => "No actionable findings", "findings" => []}

  defp reviewed_head(job),
    do: Reviews.last_reviewed_head(job, "Fix it", "Original requirements")[:head_sha]

  defp advisory,
    do: %{
      "summary" => "Nothing blocks this change.",
      "findings" => [
        %{
          "severity" => "low",
          "description" => "Two collections can record the same whole second."
        }
      ]
    }

  defp findings,
    do: %{
      "summary" => "Fix the race",
      "findings" => [
        %{"severity" => "high", "description" => "The old attempt can overwrite the new attempt."}
      ]
    }

  test "scope and risk suggest 1, 2, or 5 rounds and freeze model settings at approval" do
    assert ExecutionProfiles.suggested(%{scope: "small", risk: "low"}) == "small"
    assert ExecutionProfiles.suggested(%{scope: "small", risk: "high"}) == "strong"
    assert ExecutionProfiles.suggested(%{scope: "large", risk: "medium"}) == "strong"
    assert ExecutionProfiles.suggested(nil) == "standard"
    assert Enum.map(ExecutionProfiles.list(), & &1.max_reviews) == [1, 2, 5]

    for profile <- ExecutionProfiles.list() do
      assert profile.reviewer_model == "gpt-5.6-sol"
      assert profile.reviewer_effort == "xhigh"
    end

    job = job!(5)
    assert job.execution_settings["reviewer_model"] == "gpt-5.6-sol"
    assert job.execution_settings["reviewer_effort"] == "xhigh"
    assert job.execution_settings["model"] == "gpt-5.6-sol"

    assert {:ok, _} =
             ExecutionProfiles.save(
               "standard",
               %{
                 "model" => "another-model",
                 "reviewer_model" => "another-reviewer",
                 "reviewer_effort" => "low"
               },
               "maintainer"
             )

    frozen = Repo.get!(Job, job.id).execution_settings
    assert frozen["model"] == "gpt-5.6-sol"
    assert frozen["reviewer_model"] == "gpt-5.6-sol"
    assert frozen["reviewer_effort"] == "xhigh"
  end

  test "failed attempts do not prematurely exhaust a later completed review" do
    job = job!(2)
    {:ok, first} = request(job, "failure")
    Reviews.fail(first.id, :review_timeout)
    {:ok, continued} = Reviews.decide(job.id, 0, "continue", %{"extra_rounds" => 0}, "maintainer")
    continued |> Job.changeset(%{review_state: "changes_requested"}) |> Repo.update!()
    {:ok, second} = request(continued, "second")
    assert {:ok, _} = Reviews.complete(second.id, findings())
    assert Repo.get!(Job, job.id).review_state == "changes_requested"
    Process.put(:review_test_head, String.duplicate("d", 40))
    {:ok, third} = request(continued, "third")
    assert third.number == 3
    assert {:ok, _} = Reviews.complete(third.id, findings())
    assert Repo.get!(Job, job.id).review_state == "paused"
  end

  test "review timeouts are validated, frozen, and covered by the attempt expiry" do
    job = job!(2)
    assert job.execution_settings["review_timeout_ms"] == 900_000

    for value <- [0, 3_600_001, "invalid"] do
      assert {:error, _} =
               ExecutionProfiles.save("standard", %{"review_timeout_ms" => value}, "maintainer")
    end

    assert {:ok, _} =
             ExecutionProfiles.save("standard", %{"review_timeout_ms" => 3_600_000}, "maintainer")

    assert Repo.get!(Job, job.id).execution_settings["review_timeout_ms"] == 900_000
    long_job = job!(2)
    {:ok, round} = request(long_job, "long")
    assert round.input["settings"]["review_timeout_ms"] == 3_600_000
    assert DateTime.diff(round.expires_at, DateTime.utc_now()) >= 3600
  end

  test "continuation instructions are saved, audited, and included in the resumed prompt" do
    job = job!(1)
    job |> Job.changeset(%{review_state: "manual"}) |> Repo.update!()
    instructions = "Read all prior findings and check rollback before editing."

    assert {:ok, continued} =
             Reviews.decide(
               job.id,
               0,
               "continue",
               %{"extra_rounds" => 0, "instructions" => "  " <> instructions <> "  "},
               "maintainer"
             )

    assert continued.review_continuation_instructions == instructions
    loaded = Repo.preload(continued, [:repository, :issue])

    prompt =
      PtcManager.Dispatch.HerdrAdapter.build_prompt(loaded.repository, loaded.issue, loaded)

    assert prompt =~ instructions
    assert prompt =~ "Do not push, create a pull request, or merge"

    audit =
      Repo.get_by!(PtcManager.Operations.AuditEvent,
        target_id: job.id,
        action: "review.continued"
      )

    assert audit.details["instructions"] == instructions

    continued |> Job.changeset(%{review_state: "paused"}) |> Repo.update!()

    assert {:ok, next} =
             Reviews.decide(job.id, 1, "continue", %{"instructions" => "  "}, "maintainer")

    assert is_nil(next.review_continuation_instructions)

    refute PtcManager.Dispatch.HerdrAdapter.build_prompt(loaded.repository, loaded.issue, next) =~
             instructions
  end

  test "invalid continuation instructions do not queue a continuation" do
    job = job!(1)
    job |> Job.changeset(%{review_state: "paused"}) |> Repo.update!()

    for value <- [String.duplicate("x", 4001), %{}] do
      assert {:error, :invalid_continuation_instructions} =
               Reviews.decide(job.id, 0, "continue", %{"instructions" => value}, "maintainer")

      assert Repo.get!(Job, job.id).review_state == "paused"
      assert Repo.get!(Job, job.id).review_generation == 0
    end
  end

  test "a duplicate request counts once and a clean review approves only its exact head" do
    job = job!(2)
    assert {:ok, first} = request(job, "one")
    assert {:ok, duplicate} = request(job, "one")
    assert first.id == duplicate.id
    assert {:ok, _} = Reviews.complete(first.id, clean())
    assert length(Reviews.rounds(job.id)) == 1
    approved = Repo.get!(Job, job.id)

    assert Reviews.publication_allowed?(
             approved,
             Map.take(first, [:head_sha, :base_sha, :diff_digest])
           )

    refute Reviews.publication_allowed?(approved, %{
             head_sha: String.duplicate("d", 40),
             base_sha: first.base_sha,
             diff_digest: first.diff_digest
           })
  end

  test "a completed review cannot authorize a different base, patch, or generation" do
    job = job!(2)
    {:ok, round} = request(job, "one")
    {:ok, _} = Reviews.complete(round.id, clean())
    approved = Repo.get!(Job, job.id)
    evidence = Map.take(round, [:head_sha, :base_sha, :diff_digest])

    for field <- [:head_sha, :base_sha, :diff_digest] do
      refute Reviews.publication_allowed?(approved, Map.put(evidence, field, "changed"))
    end

    refute Reviews.publication_allowed?(%{approved | review_generation: 1}, evidence)
    assert {:ok, same} = request(job, "another-request")
    assert same.state == "cached"
    assert same.result == clean()
    assert Enum.count(Reviews.rounds(job.id), &(&1.state == "completed")) == 1
  end

  test "a reviewer is claimed once and expired work pauses without losing the branch" do
    job = job!(2)
    {:ok, round} = request(job, "one")
    assert {:ok, _} = Reviews.claim(round.id)
    assert {:error, :stale_review} = Reviews.claim(round.id)

    round
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert :ok = Reviews.sweep()
    current = Repo.get!(Job, job.id)
    assert current.review_state == "paused"
    assert current.branch_name == job.branch_name
    assert {:error, :stale_review} = Reviews.complete(round.id, clean())
  end

  test "an interrupted continuation expires independently of job heartbeat updates" do
    job = job!(1)

    job
    |> Job.changeset(%{
      review_state: "resume_pending",
      review_resume_expires_at: DateTime.add(DateTime.utc_now(), -1),
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert :ok = Reviews.sweep()
    assert Repo.get!(Job, job.id).review_state == "paused"
    assert Repo.get!(Job, job.id).branch_name == job.branch_name
  end

  defmodule FailedResume do
    def resume_review_job(_), do: {:error, :retained_agent_busy}
  end

  test "continuation cannot consume a previous agent's stop report" do
    alias PtcManager.Operations.StopReport
    job = job!(1)
    {:ok, job} = Operations.issue_stop_report_token(job)
    old_path = StopReport.path_for(job)
    File.mkdir_p!(Path.dirname(old_path))

    report = %{
      "reason_code" => "environment_broken",
      "summary" => "Old review failed",
      "detail" => "No assessment was returned",
      "progress" => "partial"
    }

    File.write!(old_path, Jason.encode!(report))
    on_exit(fn -> File.rm(old_path) end)
    assert {:ok, _} = StopReport.read(job)

    {:ok, round} = request(job, "one")
    {:ok, :ok} = Reviews.fail(round.id, :reviewer_unavailable)
    {:ok, continued} = Reviews.decide(job.id, 0, "continue", %{"extra_rounds" => 1}, "maintainer")

    refute StopReport.path_for(continued) == old_path
    assert :none = StopReport.read(continued)
    assert {:ok, _} = StopReport.read(job)
  end

  test "a failed continuation remains visible and cannot consume more budget automatically" do
    job = job!(1)
    {:ok, round} = request(job, "one")
    {:ok, _} = Reviews.complete(round.id, findings())
    {:ok, continued} = Reviews.decide(job.id, 0, "continue", %{"extra_rounds" => 1}, "maintainer")
    old = Application.get_env(:ptc_manager, :review_resume_adapter)
    Application.put_env(:ptc_manager, :review_resume_adapter, FailedResume)

    on_exit(fn ->
      if old,
        do: Application.put_env(:ptc_manager, :review_resume_adapter, old),
        else: Application.delete_env(:ptc_manager, :review_resume_adapter)
    end)

    assert :ok =
             PtcManager.Reviews.ResumeWorker.perform(%Oban.Job{
               args: %{"job_id" => job.id, "generation" => continued.review_generation}
             })

    current = Repo.get!(Job, job.id)
    assert current.review_state == "paused"
    assert current.last_error =~ "work is preserved"
    assert current.required_review_count == 2
    assert length(Reviews.rounds(job.id)) == 1
  end

  test "exhaustion pauses without ending the job, and a human extends the same job" do
    job = job!(1)
    {:ok, round} = request(job, "one")
    assert {:ok, _} = Reviews.complete(round.id, findings())
    paused = Repo.get!(Job, job.id)
    assert paused.review_state == "paused"
    assert paused.state == "working"
    assert {:ok, :paused} = request(job, "two")
    refute Reviews.publication_allowed?(paused, round.head_sha)

    assert {:ok, extended} =
             Reviews.decide(
               job.id,
               0,
               "continue",
               %{"extra_rounds" => 2, "profile" => "strong"},
               "maintainer"
             )

    assert extended.id == job.id
    assert extended.branch_name == job.branch_name
    assert extended.required_review_count == 3
    assert extended.execution_settings["model"] == "gpt-6-astra"
    assert extended.review_state == "resume_pending"
    assert length(Reviews.rounds(job.id)) == 1

    assert {:error, :review_decision_stale} =
             Reviews.decide(job.id, 0, "continue", %{"extra_rounds" => 2}, "maintainer")
  end

  test "old attempts and expired or malformed reviewer results cannot approve publication" do
    job = job!(2)
    {:ok, round} = request(job, "one")

    assert {:error, :invalid_review_result} =
             Reviews.complete(round.id, %{
               "summary" => "fine",
               "findings" => [],
               "publish" => true
             })

    job |> Job.changeset(%{fencing_token: 2}) |> Repo.update!()
    assert {:error, :stale_review} = Reviews.complete(round.id, clean())
    refute Reviews.publication_allowed?(Repo.get!(Job, job.id), round.head_sha)
  end

  test "manual takeover and cancellation preserve the branch and require a cancellation reason" do
    job = job!(1)
    {:ok, round} = request(job, "one")
    Reviews.complete(round.id, findings())
    assert {:error, :reason_required} = Reviews.decide(job.id, 0, "cancel", %{}, "maintainer")
    assert {:ok, manual} = Reviews.decide(job.id, 0, "manual", %{}, "maintainer")
    assert manual.review_state == "manual"
    assert manual.branch_name == job.branch_name

    assert {:ok, cancelled} =
             Reviews.decide(
               job.id,
               1,
               "cancel",
               %{"reason" => "Taking a different approach"},
               "maintainer"
             )

    assert cancelled.review_state == "cancelled"
    assert cancelled.branch_name == job.branch_name
    refute Reviews.publication_allowed?(cancelled, round.head_sha)
  end

  test "reviewer failures preserve evidence without spending completed review budget" do
    job = job!(1)
    {:ok, round} = request(job, "one")
    assert {:ok, :ok} = Reviews.fail(round.id, :model_unavailable)
    assert Repo.get!(Job, job.id).review_state == "paused"
    assert [%{state: "failed", input: %{"diff" => "a bounded patch"}}] = Reviews.rounds(job.id)
    assert {:ok, :paused} = request(job, "another")

    assert {:ok, continued} =
             Reviews.decide(job.id, 0, "continue", %{"extra_rounds" => 0}, "maintainer")

    assert continued.required_review_count == 1
    continued |> Job.changeset(%{review_state: "changes_requested"}) |> Repo.update!()
    assert {:ok, retry} = request(continued, "retry")
    assert retry.number == 2
    assert {:ok, _} = Reviews.complete(retry.id, findings())
    assert Repo.get!(Job, job.id).review_state == "paused"

    assert {:error, :review_budget_exhausted} =
             Reviews.decide(job.id, 1, "continue", %{"extra_rounds" => 0}, "maintainer")
  end
end
