defmodule PtcManager.CollectionsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.{Collections, Operations, Repo}
  alias PtcManager.Collections.{Member, Run, Step, Structure}
  alias PtcManager.Operations.{AgentAction, Issue, Job, PrPublication}

  defmodule PullClient do
    alias PtcManager.Operations.{PrPublication, Repository}

    def list_open(_repository), do: {:ok, []}

    # The real client reads the publication's repository to build the GitHub
    # URL; a publication handed over without it fails exactly as it did in
    # production, where the merge was deferred on every pass.
    def status(%PrPublication{repository: %Repository{}}),
      do: Process.get(:collection_status, {:error, :no_status})

    def status(%PrPublication{}), do: raise("publication repository is not loaded")
  end

  defmodule FakeSourceSnapshot do
    def capture(repository),
      do: {:ok, %{sha: String.duplicate("7", 40), ref: repository.default_branch}}
  end

  setup do
    previous_client = Application.fetch_env!(:ptc_manager, :pull_request_client)
    previous_snapshot = Application.get_env(:ptc_manager, :planning_source_snapshot)
    Application.put_env(:ptc_manager, :pull_request_client, PullClient)
    Application.put_env(:ptc_manager, :planning_source_snapshot, FakeSourceSnapshot)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :pull_request_client, previous_client)

      if previous_snapshot,
        do: Application.put_env(:ptc_manager, :planning_source_snapshot, previous_snapshot),
        else: Application.delete_env(:ptc_manager, :planning_source_snapshot)
    end)

    :ok
  end

  # An umbrella with labelled members; `chain: true` blocks each member by the
  # previous one so only the first can start.
  defp collection_fixture(repository, numbers, opts \\ []) do
    umbrella =
      issue_fixture(repository, %{number: 1000, sub_issues: nodes(repository, numbers, %{})})

    members =
      Enum.map(numbers, fn number ->
        issue_fixture(repository, %{
          number: number,
          parent_issue_number: umbrella.number,
          workflow_label: Keyword.get(opts, :label, "ptc:ready")
        })
      end)

    if Keyword.get(opts, :chain, false) do
      members
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [blocker, dependent] ->
        issue_dependency_fixture(dependent, %{
          blocking_issue: blocker,
          blocking_repository: repository
        })
      end)
    end

    {Repo.reload!(umbrella), members}
  end

  defp nodes(repository, numbers, states) do
    %{
      "nodes" =>
        Enum.map(numbers, fn number ->
          %{
            "number" => number,
            "state" => Map.get(states, number, "open"),
            "state_reason" => if(Map.get(states, number) == "closed", do: "completed"),
            "repository_full_name" => Structure.repository_full_name(repository)
          }
        end),
      "total" => length(numbers)
    }
  end

  defp refresh_umbrella(umbrella, repository, numbers, states) do
    umbrella
    |> Repo.reload!()
    |> Issue.changeset(%{sub_issues: nodes(repository, numbers, states)})
    |> Repo.update!()
  end

  defp start!(umbrella, attrs \\ %{}) do
    {:ok, run} = Collections.start(umbrella.id, attrs, "andreas")
    run
  end

  defp steps(run), do: Repo.all(from s in Step, where: s.run_id == ^run.id, order_by: s.id)

  defp collection_actions(repository) do
    Repo.all(
      from a in AgentAction,
        where: a.repository_id == ^repository.id and a.actor == "system:collection",
        order_by: a.id
    )
  end

  defp job_for(issue) do
    Repo.one(from j in Job, where: j.issue_id == ^issue.id, order_by: [desc: j.id], limit: 1)
  end

  defp finish_action(action, outcome, created \\ []) do
    action
    |> AgentAction.changeset(%{
      state: "done",
      result_summary: Jason.encode!(%{"outcome" => outcome, "created_issue_numbers" => created})
    })
    |> Repo.update!()
  end

  # Turns a member's job into an open, green, reviewed publication.
  defp open_publication!(issue, job, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    job
    |> Job.changeset(%{
      state: "pr_open",
      required_review_count: 0,
      review_state: "skipped",
      result_head_sha: String.duplicate("b", 40)
    })
    |> Repo.update!()

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      repository_id: issue.repository_id,
      state: "published",
      idempotency_key: :crypto.hash(:sha256, "pub-#{issue.id}") |> Base.encode16(case: :lower),
      fencing_token: job.fencing_token,
      branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}",
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: 500 + issue.number,
      pr_url: "https://github.com/example/repo/pull/#{500 + issue.number}",
      remote_head_sha: String.duplicate("b", 40),
      remote_base_sha: String.duplicate("a", 40),
      published_at: now,
      pr_state: Keyword.get(opts, :pr_state, "open"),
      pr_checked_at: now,
      source: "broker",
      draft: true,
      checks_state: Keyword.get(opts, :checks_state, "success"),
      mergeability: Keyword.get(opts, :mergeability, "mergeable"),
      linked_issue_numbers: %{"numbers" => [issue.number]}
    })
    |> Repo.insert!()
  end

  defp fresh_status(publication, repository, overrides \\ %{}) do
    Map.merge(
      %{
        pr_number: publication.pr_number,
        pr_url: publication.pr_url,
        state: "open",
        draft: true,
        head_sha: publication.remote_head_sha,
        base_sha: publication.base_sha,
        base_ref: repository.default_branch,
        base_repository: "#{repository.github_owner}/#{repository.github_name}",
        mergeability: "mergeable",
        mergeable_state: "clean",
        checks_state: "success",
        checks_total: 1,
        checks_failed: 0,
        checks_pending: 0
      },
      overrides
    )
  end

  defp merged!(issue, job, umbrella, repository, numbers, closed) do
    publication = open_publication!(issue, job, pr_state: "merged")
    job |> Repo.reload!() |> Job.changeset(%{state: "done"}) |> Repo.update!()

    issue
    |> Repo.reload!()
    |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
    |> Repo.update!()

    for dependency <-
          Repo.all(
            from d in PtcManager.Operations.IssueDependency,
              where: d.blocking_issue_id == ^issue.id
          ) do
      dependency
      |> PtcManager.Operations.IssueDependency.changeset(%{
        blocking_state: "closed",
        blocking_state_reason: "completed"
      })
      |> Repo.update!()
    end

    {publication, refresh_umbrella(umbrella, repository, numbers, closed)}
  end

  describe "start/3" do
    test "freezes the membership, validates the structure, and refuses a second live run" do
      repository = repository_fixture()
      {umbrella, _members} = collection_fixture(repository, [1, 2], chain: true)

      assert {:ok, run} = Collections.start(umbrella.id, %{auto_merge: false}, "andreas")
      assert run.state == "active"
      refute run.auto_merge
      assert run.auto_recover

      assert Repo.all(from m in Member, where: m.run_id == ^run.id) |> Enum.map(& &1.issue_number) ==
               [1, 2]

      assert {:error, :run_already_live} = Collections.start(umbrella.id, %{}, "andreas")

      plain = issue_fixture(repository, %{number: 2000})
      assert {:error, :not_a_collection} = Collections.start(plain.id, %{}, "andreas")

      {unlabelled, _} = collection_fixture(repository_fixture(), [3, 4], label: nil)

      assert {:error, {:structure_invalid, {:member_without_workflow_label, 3}}} =
               Collections.start(unlabelled.id, %{}, "andreas")

      disabled = repository_fixture(%{enabled: false})
      {off, _} = collection_fixture(disabled, [5, 6])
      assert {:error, :repository_disabled} = Collections.start(off.id, %{}, "andreas")
    end
  end

  describe "admission" do
    test "admits only ready, unblocked members, once each, under the run's own approval" do
      repository = repository_fixture()
      {umbrella, [first, second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)

      assert :ok = Collections.reconcile(repository.id)
      assert %Job{state: "queued"} = job = job_for(first)

      assert Repo.get!(PtcManager.Operations.Approval, job.approval_id).decision ==
               "start_implementation_collection"

      assert is_nil(job_for(second))
      assert [%Step{kind: "admit", scope: "1", job_id: job_id}] = steps(run)
      assert job_id == job.id

      # Idempotent: a second pass admits nothing new.
      assert :ok = Collections.reconcile(repository.id)
      assert length(steps(run)) == 1
      assert Repo.aggregate(Job, :count) == 1

      # The gate refuses an outsider and a member of a paused run.
      outsider = issue_fixture(repository, %{number: 50, workflow_label: "ptc:ready"})

      assert {:error, :no_active_collection_run} =
               Operations.approve_collection_issue(outsider.id)

      {:ok, _paused} = Collections.pause(run.id, "andreas")
      assert {:error, :no_active_collection_run} = Operations.approve_collection_issue(second.id)

      remote = %{
        workflow_label: "ptc:ready",
        workflow_label_conflict: false,
        structure_projected: true,
        sub_issues: %{"nodes" => [], "total" => 0},
        github_assignees: %{"logins" => []}
      }

      job = job |> Repo.preload([:approval, :repository, :issue])

      assert {:error, :no_active_collection_run} =
               PtcManager.AutoImplementation.dispatch_allowed(job, remote)

      {:ok, _resumed} = Collections.resume(run.id, "andreas")
      assert :ok = PtcManager.AutoImplementation.dispatch_allowed(job, remote)

      assert {:error, :issue_claimed} =
               PtcManager.AutoImplementation.dispatch_allowed(job, %{
                 remote
                 | github_assignees: %{"logins" => ["x"]}
               })

      # The console's own agent assigns the issue while it works; that claim
      # must not stop the console from running the issue again.
      repository =
        repository
        |> PtcManager.Operations.Repository.changeset(%{github_viewer_login: "console-bot"})
        |> Repo.update!()

      job = %{job | repository: repository}

      assert :ok =
               PtcManager.AutoImplementation.dispatch_allowed(job, %{
                 remote
                 | github_assignees: %{"logins" => ["console-bot"]}
               })

      assert {:error, :issue_claimed} =
               PtcManager.AutoImplementation.dispatch_allowed(job, %{
                 remote
                 | github_assignees: %{"logins" => ["console-bot", "x"]}
               })
    end
  end

  describe "handoff and merge" do
    test "a merged member gets one handoff, admission waits for it, then the next member starts" do
      repository = repository_fixture()
      {umbrella, [first, second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)
      assert :ok = Collections.reconcile(repository.id)
      job = job_for(first)

      {publication, _umbrella} =
        merged!(first, job, umbrella, repository, [1, 2], %{1 => "closed"})

      assert :ok = Collections.reconcile(repository.id)

      assert [%AgentAction{action_key: "collection_handoff", state: "queued"} = handoff] =
               collection_actions(repository)

      assert handoff.target_id == umbrella.id
      assert handoff.target_snapshot["merged_publication_id"] == publication.id
      assert handoff.prompt =~ "merged_member=\"1\""

      assert Enum.any?(
               steps(run),
               &(&1.kind == "handoff" and &1.scope == "#{publication.id}:attempt:1")
             )

      # Nothing else moves while the handoff is outstanding.
      assert :ok = Collections.reconcile(repository.id)
      assert is_nil(job_for(second))

      finish_action(handoff, "no-changes")
      assert :ok = Collections.reconcile(repository.id)
      assert %Job{state: "queued"} = job_for(second)
      assert length(collection_actions(repository)) == 1
    end

    test "a merge at an unauthorized head is not delivery until the maintainer says so" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)
      job = job_for(first)
      publication = open_publication!(first, job)

      {:ok, merge} =
        PtcManager.MaintainerActions.enqueue(
          "merge_reviewed_pr",
          publication.id,
          "system:collection"
        )

      publication |> PrPublication.changeset(%{pr_state: "merged"}) |> Repo.update!()
      job |> Repo.reload!() |> Job.changeset(%{state: "done"}) |> Repo.update!()

      first
      |> Repo.reload!()
      |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
      |> Repo.update!()

      refresh_umbrella(umbrella, repository, [1], %{1 => "closed"})

      merge
      |> AgentAction.changeset(%{
        state: "failed",
        last_error: "postflight_failed: :unexpected_merge_head",
        target_snapshot: %{"authorized_head_sha" => String.duplicate("a", 40)}
      })
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)

      assert %Run{state: "paused", pause_kind: "action_failed", pause_reference_id: reference} =
               Repo.get!(Run, run.id)

      assert reference == merge.id
      refute Enum.any?(collection_actions(repository), &(&1.action_key == "collection_handoff"))

      # It stays paused until an explicit override, then the handoff proceeds.
      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused"} = Repo.get!(Run, run.id)
      {:ok, _resumed} = Collections.resume(run.id, "andreas")
      assert :ok = Collections.reconcile(repository.id)
      assert Enum.any?(collection_actions(repository), &(&1.action_key == "collection_handoff"))
    end

    test "a failed handoff is retried once, then pauses the run" do
      repository = repository_fixture()
      {umbrella, [first, _second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)

      {_publication, _} =
        merged!(first, job_for(first), umbrella, repository, [1, 2], %{1 => "closed"})

      :ok = Collections.reconcile(repository.id)

      [handoff] = collection_actions(repository)
      handoff |> AgentAction.changeset(%{state: "failed", last_error: "boom"}) |> Repo.update!()
      :ok = Collections.reconcile(repository.id)

      assert [_failed, %AgentAction{state: "queued"} = second_attempt] =
               collection_actions(repository)

      assert Enum.count(steps(run), &(&1.kind == "handoff")) == 2

      second_attempt
      |> AgentAction.changeset(%{state: "failed", last_error: "boom again"})
      |> Repo.update!()

      :ok = Collections.reconcile(repository.id)
      # The failed handoff pauses as a failed action, since the handoff scope is exhausted.
      assert %Run{state: "paused"} = Repo.get!(Run, run.id)
    end

    test "a green reviewed publication is merged once at its exact head after a fresh status read" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)
      job = job_for(first)
      publication = open_publication!(first, job)

      # A stale local green is not enough: GitHub is asked again.
      Process.put(
        :collection_status,
        {:ok, fresh_status(publication, repository, %{checks_state: "failure", checks_failed: 1})}
      )

      assert :ok = Collections.reconcile(repository.id)
      assert collection_actions(repository) == []
      assert Repo.get!(PrPublication, publication.id).checks_state == "failure"

      # Now it pauses instead of repairing: a repaired head would be unreviewed.
      assert :ok = Collections.reconcile(repository.id)

      assert %Run{state: "paused", pause_kind: "child_merge_blocked", paused_issue_number: 1} =
               Repo.get!(Run, run.id)

      # The checks go green again on the same head: the pause clears and the merge is queued.
      Process.put(:collection_status, {:ok, fresh_status(publication, repository)})

      Repo.get!(PrPublication, publication.id)
      |> PrPublication.changeset(%{checks_state: "success"})
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "active"} = Repo.get!(Run, run.id)
      assert :ok = Collections.reconcile(repository.id)

      assert [%AgentAction{action_key: "merge_reviewed_pr", state: "queued"} = merge] =
               collection_actions(repository)

      assert merge.target_snapshot["authorized_head_sha"] == String.duplicate("b", 40)

      assert Enum.any?(
               steps(run),
               &(&1.kind == "merge" and
                   &1.scope == "#{publication.id}:#{String.duplicate("b", 40)}")
             )

      # A repeated pass enqueues nothing, and auto_merge off never merges.
      assert :ok = Collections.reconcile(repository.id)
      assert length(collection_actions(repository)) == 1
      Run |> where([r], r.id == ^run.id) |> Repo.update_all(set: [auto_merge: false])
      merge |> AgentAction.changeset(%{state: "cancelled"}) |> Repo.update!()
      Repo.delete_all(from s in Step, where: s.run_id == ^run.id and s.kind == "merge")
      assert :ok = Collections.reconcile(repository.id)
      assert length(collection_actions(repository)) == 1
    end
  end

  describe "recovery and escalation" do
    test "a member answered on GitHub after its blocker report is admitted again, once" do
      repository = repository_fixture(%{github_viewer_login: "console-bot"})
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)
      job = job_for(first)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      job
      |> Job.changeset(%{
        state: "failed",
        stop_report: %{
          "reason_code" => "ambiguous_requirement",
          "summary" => "Which shape?",
          "detail" => "d",
          "progress" => "none"
        },
        stop_reported_at: now,
        ended_at: now
      })
      |> Repo.update!()

      # The stop asks the question on the issue; the agent labels it and, as
      # every agent does, assigns it to the console's own identity.
      :ok = Collections.reconcile(repository.id)
      assert [%AgentAction{} = ask] = collection_actions(repository)
      finish_action(ask, "needs-decision")

      first
      |> Issue.changeset(%{
        workflow_label: "ptc:needs-decision",
        github_assignees: %{"logins" => ["console-bot"]},
        content_digest: "asked"
      })
      |> Repo.update!()

      :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused", pause_kind: "child_needs_decision"} = Repo.get!(Run, run.id)

      # The maintainer answers and marks the issue ready again.
      Issue
      |> Repo.get!(first.id)
      |> Issue.changeset(%{workflow_label: "ptc:ready", content_digest: "answered"})
      |> Repo.update!()

      :ok = Collections.reconcile(repository.id)
      assert %Run{state: "active"} = Repo.get!(Run, run.id)
      :ok = Collections.reconcile(repository.id)

      assert %Job{state: "queued"} = again = job_for(first)
      assert again.id != job.id
      assert again.approval_id != job.approval_id
      assert Enum.any?(steps(run), &(&1.kind == "admit" and &1.scope == "1:after:#{job.id}"))

      # Stable: no second admission and no pause on the next passes.
      :ok = Collections.reconcile(repository.id)
      :ok = Collections.reconcile(repository.id)
      assert job_for(first).id == again.id
      assert %Run{state: "active"} = Repo.get!(Run, run.id)
      assert Repo.aggregate(Job, :count) == 2
    end

    test "a stop report is retried once; the second stop pauses and escalates on the umbrella" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)
      job = job_for(first)

      stop = fn job ->
        job
        |> Job.changeset(%{
          state: "failed",
          stop_report: %{
            "reason_code" => "environment_broken",
            "summary" => "No compiler.",
            "detail" => "d",
            "progress" => "none"
          },
          stop_reported_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now()
        })
        |> Repo.update!()
      end

      stop.(job)
      assert :ok = Collections.reconcile(repository.id)
      assert %Job{state: "queued"} = retry = job_for(first)
      assert retry.id != job.id
      assert Enum.any?(steps(run), &(&1.kind == "retry" and &1.scope == "member:1"))
      assert %Run{state: "active"} = Repo.get!(Run, run.id)

      # One automatic retry per member, whichever job it came from: the second
      # stop is the maintainer's.
      stop.(retry)
      second_retry = retry
      assert :ok = Collections.reconcile(repository.id)
      assert job_for(first).id == retry.id

      assert %Run{state: "paused", pause_kind: "child_attempt_failed", escalation_pending: true} =
               paused = Repo.get!(Run, run.id)

      assert paused.paused_issue_number == 1

      assert :ok = Collections.reconcile(repository.id)

      assert [%AgentAction{action_key: "report_collection_blocker", state: "queued"} = escalation] =
               collection_actions(repository)

      assert escalation.target_id == umbrella.id
      assert escalation.target_snapshot["allowed_outcomes"] == ["needs-decision"]
      assert escalation.prompt =~ "Member that stopped the run: #1"
      refute Repo.get!(Run, run.id).escalation_pending

      # The maintainer retries by hand: a newer job clears the pause.
      {:ok, _manual} = Operations.retry_stopped_job(second_retry.id, "andreas")
      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "active", pause_kind: nil} = Repo.get!(Run, run.id)
    end

    test "a failed escalation is attempted once more, then the console is the notification" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella, %{auto_recover: false})
      :ok = Collections.reconcile(repository.id)

      job_for(first)
      |> Job.changeset(%{state: "lost", ended_at: DateTime.utc_now(), last_error: "gone"})
      |> Repo.update!()

      :ok = Collections.reconcile(repository.id)
      :ok = Collections.reconcile(repository.id)

      assert [%AgentAction{action_key: "report_collection_blocker"} = first_attempt] =
               collection_actions(repository)

      first_attempt
      |> AgentAction.changeset(%{state: "failed", last_error: "gh down"})
      |> Repo.update!()

      :ok = Collections.reconcile(repository.id)

      assert [
               _failed,
               %AgentAction{action_key: "report_collection_blocker", state: "queued"} = second
             ] = collection_actions(repository)

      assert Enum.count(steps(run), &(&1.kind == "escalation")) == 2

      second |> AgentAction.changeset(%{state: "failed", last_error: "gh down"}) |> Repo.update!()
      :ok = Collections.reconcile(repository.id)
      assert length(collection_actions(repository)) == 2
      assert %Run{state: "paused", escalation_pending: false} = Repo.get!(Run, run.id)
    end

    test "with automatic recovery off, the first stuck member pauses the run" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella, %{auto_recover: false})
      :ok = Collections.reconcile(repository.id)

      job_for(first)
      |> Job.changeset(%{state: "lost", ended_at: DateTime.utc_now(), last_error: "gone"})
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused", pause_kind: "child_attempt_failed"} = Repo.get!(Run, run.id)
      assert steps(run) |> Enum.map(& &1.kind) == ["admit"]
    end

    test "an exhausted review is continued once with more rounds, a manual takeover never" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)

      job =
        job_for(first)
        |> Job.changeset(%{
          state: "blocked",
          review_state: "paused",
          last_error: "budget exhausted"
        })
        |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)
      continued = Repo.get!(Job, job.id)
      assert continued.review_state == "resume_pending"
      assert continued.required_review_count == job.required_review_count + 2
      assert continued.execution_settings["name"] == "strong"
      assert Enum.any?(steps(run), &(&1.kind == "review_continue" and &1.scope == "member:1"))

      # One continuation per member: a second exhaustion pauses the run.
      continued |> Job.changeset(%{review_state: "paused"}) |> Repo.update!()
      assert :ok = Collections.reconcile(repository.id)
      assert Repo.get!(Job, job.id).review_state == "paused"
      assert %Run{state: "paused", pause_kind: "child_review_held"} = Repo.get!(Run, run.id)

      # A manual takeover is the maintainer's decision: no continuation, a pause.
      other_repository = repository_fixture()
      {other_umbrella, [other_first]} = collection_fixture(other_repository, [1])
      other_run = start!(other_umbrella)
      :ok = Collections.reconcile(other_repository.id)

      job_for(other_first)
      |> Job.changeset(%{state: "blocked", review_state: "manual"})
      |> Repo.update!()

      assert :ok = Collections.reconcile(other_repository.id)
      assert %Run{state: "paused", pause_kind: "child_review_held"} = Repo.get!(Run, other_run.id)
      refute Enum.any?(steps(other_run), &(&1.kind in ["review_continue", "review_retry"]))
    end

    test "resume is a scoped override that does not repeat for the same scope" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella, %{auto_recover: false})
      :ok = Collections.reconcile(repository.id)

      job_for(first)
      |> Job.changeset(%{state: "cancelled", ended_at: DateTime.utc_now()})
      |> Repo.update!()

      :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused", pause_scope: scope} = Repo.get!(Run, run.id)

      assert {:ok, %Run{state: "active"}} = Collections.resume(run.id, "andreas")
      assert Enum.any?(steps(run), &(&1.kind == "override" and &1.scope == scope))
      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "active"} = Repo.get!(Run, run.id)
      assert {:error, :run_not_paused} = Collections.resume(run.id, "andreas")
    end
  end

  describe "membership" do
    test "drift pauses the run until the maintainer accepts the new membership" do
      repository = repository_fixture()
      {umbrella, [_first, _second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)

      issue_fixture(repository, %{
        number: 3,
        parent_issue_number: umbrella.number,
        workflow_label: "ptc:ready"
      })

      refresh_umbrella(umbrella, repository, [1, 2, 3], %{})

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused", pause_kind: "membership_changed"} = Repo.get!(Run, run.id)
      assert {:error, :accept_changes_required} = Collections.resume(run.id, "andreas")

      assert {:ok, %Run{state: "active"}} = Collections.accept_changes(run.id, "andreas")

      assert Repo.all(from m in Member, where: m.run_id == ^run.id) |> Enum.map(& &1.issue_number) ==
               [1, 2, 3]

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "active"} = Repo.get!(Run, run.id)
    end

    test "a foreign issue with a member's number is drift, not the member" do
      repository = repository_fixture()
      {umbrella, [_first]} = collection_fixture(repository, [1])
      run = start!(umbrella)

      umbrella
      |> Repo.reload!()
      |> Issue.changeset(%{
        sub_issues: %{
          "nodes" => [%{"number" => 1, "state" => "open", "repository_full_name" => "other/repo"}],
          "total" => 1
        }
      })
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused", pause_kind: "membership_changed"} = Repo.get!(Run, run.id)
    end

    test "accepting changes refuses to drop a member that is being worked on" do
      repository = repository_fixture()
      {umbrella, [first, _second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)
      assert %Job{} = job_for(first)

      refresh_umbrella(umbrella, repository, [2], %{})
      :ok = Collections.reconcile(repository.id)
      assert %Run{state: "paused", pause_kind: "membership_changed"} = Repo.get!(Run, run.id)
      assert {:error, {:member_in_flight, 1}} = Collections.accept_changes(run.id, "andreas")
    end

    test "issues a handoff created are adopted as members" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)

      {_publication, _} =
        merged!(first, job_for(first), umbrella, repository, [1], %{1 => "closed"})

      :ok = Collections.reconcile(repository.id)
      [handoff] = collection_actions(repository)

      issue_fixture(repository, %{
        number: 7,
        parent_issue_number: umbrella.number,
        workflow_label: "ptc:ready"
      })

      refresh_umbrella(umbrella, repository, [1, 7], %{1 => "closed"})
      finish_action(handoff, "completed", [7])

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "active"} = Repo.get!(Run, run.id)
      assert Repo.get_by!(Member, run_id: run.id, issue_number: 7).added_by == "handoff"

      assert %Job{state: "queued"} =
               job_for(Repo.get_by!(Issue, repository_id: repository.id, number: 7))
    end
  end

  describe "ending" do
    test "pause and cancel remove queued collection actions and their steps" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)

      {_publication, _} =
        merged!(first, job_for(first), umbrella, repository, [1], %{1 => "closed"})

      :ok = Collections.reconcile(repository.id)
      assert [%AgentAction{state: "queued"} = handoff] = collection_actions(repository)

      assert {:ok, %Run{state: "paused"}} = Collections.pause(run.id, "andreas")
      assert Repo.get!(AgentAction, handoff.id).state == "cancelled"
      refute Enum.any?(steps(run), &(&1.kind == "handoff"))

      assert {:ok, %Run{state: "active"}} = Collections.resume(run.id, "andreas")
      assert {:ok, %Run{state: "cancelled"}} = Collections.cancel(run.id, "andreas")
      assert {:error, :run_not_live} = Collections.cancel(run.id, "andreas")
      assert is_nil(Collections.current_run(umbrella.id))
    end

    test "close-out runs once every member is delivered; the run finishes and completes on closure" do
      repository = repository_fixture()
      {umbrella, [first]} = collection_fixture(repository, [1])
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)

      {_publication, umbrella} =
        merged!(first, job_for(first), umbrella, repository, [1], %{1 => "closed"})

      :ok = Collections.reconcile(repository.id)
      [handoff] = collection_actions(repository)
      finish_action(handoff, "no-changes")

      assert :ok = Collections.reconcile(repository.id)

      assert [
               _handoff,
               %AgentAction{action_key: "collection_closeout", state: "queued"} = closeout
             ] = collection_actions(repository)

      assert closeout.prompt =~ "Members, all closed as completed"
      assert Enum.any?(steps(run), &(&1.kind == "closeout" and &1.scope == "attempt:1"))

      finish_action(closeout, "needs-decision")
      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "finishing"} = Repo.get!(Run, run.id)

      umbrella
      |> Repo.reload!()
      |> Issue.changeset(%{state: "closed", github_state_reason: "completed"})
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "completed"} = Repo.get!(Run, run.id)
    end

    test "an umbrella closed with unfinished members cancels the run" do
      repository = repository_fixture()
      {umbrella, [_first, _second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)
      :ok = Collections.reconcile(repository.id)

      umbrella
      |> Repo.reload!()
      |> Issue.changeset(%{state: "closed", github_state_reason: "not_planned"})
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)
      assert %Run{state: "cancelled", end_reason: "umbrella_closed"} = Repo.get!(Run, run.id)
    end

    test "a member closed without completion pauses the run" do
      repository = repository_fixture()
      {umbrella, [first, _second]} = collection_fixture(repository, [1, 2], chain: true)
      run = start!(umbrella)

      first
      |> Issue.changeset(%{state: "closed", github_state_reason: "not_planned"})
      |> Repo.update!()

      assert :ok = Collections.reconcile(repository.id)

      assert %Run{state: "paused", pause_kind: "child_closed_without_completion"} =
               Repo.get!(Run, run.id)
    end
  end

  test "nothing is touched outside the active mode or for a disabled repository" do
    repository = repository_fixture()
    {umbrella, [_first]} = collection_fixture(repository, [1])
    _run = start!(umbrella)
    repository |> PtcManager.Operations.Repository.changeset(%{enabled: false}) |> Repo.update!()
    assert :ok = Collections.reconcile(repository.id)
    assert Repo.aggregate(Job, :count) == 0
  end
end
