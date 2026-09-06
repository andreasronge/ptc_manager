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
         "issue" => "Fix it"
       }}
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
    assert same.id == round.id
    assert length(Reviews.rounds(job.id)) == 1
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
