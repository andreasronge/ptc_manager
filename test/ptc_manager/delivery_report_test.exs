defmodule PtcManager.DeliveryReportTest do
  use PtcManager.DataCase, async: false
  import PtcManager.OperationsFixtures
  alias PtcManager.{Repo, Operations, DeliveryReport}
  alias PtcManager.Operations.{Job, AuditEvent, PrPublication}

  defp job do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 2, "small")
    job
  end

  defp history(id, action),
    do: PtcManager.DeliveryHistory.events(id) |> Enum.filter(&(&1.action == action))

  test "missing metrics are unknown and evidence reads do not change the job" do
    job = job()
    count = Repo.aggregate(AuditEvent, :count)
    report = DeliveryReport.load(job.id)
    assert report.elapsed_ms == nil
    assert report.ready_ms == nil
    assert report.groups == []
    assert report.usage.input == nil
    assert report.usage.measured == 0
    assert DeliveryReport.sum_known([nil, nil]) == nil
    assert DeliveryReport.sum_known([nil, 0]) == 0
    assert Repo.aggregate(AuditEvent, :count) == count
  end

  test "bulk phase transitions are atomic, ignore heartbeats, and stop at recorded boundaries" do
    job = job()
    {1, _} = Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [state: "starting"])
    job = Repo.get!(Job, job.id)

    job
    |> Job.changeset(%{lease_expires_at: DateTime.add(DateTime.utc_now(), 60)})
    |> Repo.update!()

    job = job |> Job.changeset(%{state: "working"}) |> Repo.update!()
    events = history(job.id, "job.phase_changed")
    assert length(events) == 3
    assert Enum.at(events, 1).details["from"] == "implementation_queue"
    assert Enum.at(events, 1).details["to"] == "workspace_and_startup"

    assert [%{phase: "implementation_queue"}, %{phase: "workspace_and_startup"}] =
             DeliveryReport.phase_intervals(events)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               Repo.update_all(from(j in Job, where: j.id == ^job.id),
                 set: [review_state: "paused"]
               )

               Repo.rollback(:rollback)
             end)

    assert length(history(job.id, "job.phase_changed")) == 3
  end

  test "ready events include bulk publication, are versioned, and do not repeat on polling" do
    job = job() |> Job.changeset(%{state: "working"}) |> Repo.update!()
    head = String.duplicate("b", 40)

    pub =
      Repo.insert!(
        PrPublication.changeset(%PrPublication{}, %{
          job_id: job.id,
          state: "queued",
          pr_state: "open",
          draft: false,
          checks_state: "success",
          mergeability: "mergeable",
          remote_head_sha: head,
          head_sha: head,
          base_sha: String.duplicate("a", 40),
          diff_digest: String.duplicate("c", 64),
          branch_name: "demo",
          fencing_token: 0,
          idempotency_key: String.duplicate("d", 64)
        })
      )

    Repo.update_all(from(p in PrPublication, where: p.id == ^pub.id), set: [state: "published"])
    pub = Repo.get!(PrPublication, pub.id)
    pub |> PrPublication.changeset(%{pr_checked_at: DateTime.utc_now()}) |> Repo.update!()
    assert length(history(job.id, "delivery.ready_entered")) == 1
    assert DeliveryReport.load(job.id).ready_at

    pub
    |> PrPublication.changeset(%{remote_head_sha: String.duplicate("e", 40)})
    |> Repo.update!()

    assert length(history(job.id, "delivery.ready_entered")) == 2
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [review_state: "paused"])
    assert length(history(job.id, "delivery.ready_left")) == 1

    Repo.update_all(from(j in Job, where: j.id == ^job.id),
      set: [state: "done", review_state: "passed"]
    )

    assert length(history(job.id, "delivery.ready_entered")) == 2
  end

  test "comment observation time is frozen separately from approval time" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    observed = DateTime.add(DateTime.utc_now(), -3600, :second)

    issue
    |> Ecto.Changeset.change(github_comment_count: 7, comments_checked_at: observed)
    |> Repo.update!()

    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer", 2, "small")
    assert job.execution_settings["issue_comment_count_at_submission"] == 7

    assert job.execution_settings["issue_comments_observed_at_submission"] ==
             DateTime.to_iso8601(observed)

    issue |> Ecto.Changeset.change(github_comment_count: 9) |> Repo.update!()
    assert Repo.get!(Job, job.id).execution_settings["issue_comment_count_at_submission"] == 7
  end

  test "resource counters reject negative and arbitrary fields and calculate average cores" do
    alias PtcManager.Operations.ResourceOperation

    assert PtcManager.DeliveryMetrics.average_cores(%{
             resource_metrics: %{"cpu_usage_usec" => 180_000_000},
             run_duration_ms: 60_000
           }) == 3.0

    assert PtcManager.DeliveryMetrics.average_cores(%{
             resource_metrics: nil,
             run_duration_ms: 60_000
           }) == nil

    for metrics <- [
          %{"cpu_usage_usec" => -1},
          %{"secret" => "arbitrary"},
          %{"allowed_cpus" => 1.2}
        ] do
      changeset = ResourceOperation.changeset(%ResourceOperation{}, %{resource_metrics: metrics})
      assert Keyword.has_key?(changeset.errors, :resource_metrics)
    end
  end
end
