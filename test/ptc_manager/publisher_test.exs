defmodule PtcManager.PublisherTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AgentAction,
    AuditEvent,
    Job,
    MergeApproval,
    PrAnalysis,
    PrPublication,
    Repository,
    WorktreeAllocation
  }

  alias PtcManager.{
    MaintainerActions,
    PublicationStatusPoller,
    PublicationStatusReconciler,
    Publications,
    Publisher,
    Repo
  }

  defmodule FakeProbe do
    @behaviour PtcManager.Repository.ResultProbe

    def verify(_repository, _job) do
      send(Process.get(:publisher_test_pid), :probe_called)
      Process.get(:publisher_probe_result)
    end
  end

  defmodule FakeBroker do
    @behaviour PtcManager.GitHub.PublishBroker

    def publish(publication) do
      send(Process.get(:publisher_test_pid), {:broker_called, publication.id})
      Process.get(:publisher_broker_result)
    end

    def status(publication) do
      send(Process.get(:publisher_test_pid), {:status_called, publication.id})
      Process.get(:publisher_status_result)
    end

    def discover(publication) do
      send(Process.get(:publisher_test_pid), {:discovery_called, publication.id})
      Process.get(:publisher_discovery_result)
    end
  end

  defmodule FakeGate do
    def verify(publication) do
      send(Application.fetch_env!(:ptc_manager, :publisher_test_pid), {
        :gate_called,
        publication.id
      })

      Application.get_env(:ptc_manager, :publisher_gate_result) ||
        {:ok,
         %{
           status: "passed",
           verified_sha: publication.head_sha,
           config_digest: publication.job.pre_publication_config_digest,
           exit_status: 0,
           output: "gate passed",
           output_truncated: false,
           duration_ms: 25
         }}
    end
  end

  defmodule SlowGate do
    def verify(publication) do
      send(Application.fetch_env!(:ptc_manager, :publisher_test_pid), {
        :slow_gate_started,
        publication.id
      })

      Process.sleep(Application.fetch_env!(:ptc_manager, :publisher_slow_gate_ms))

      {:ok,
       %{
         status: "passed",
         verified_sha: publication.head_sha,
         config_digest: publication.job.pre_publication_config_digest,
         exit_status: 0,
         output: "slow gate passed",
         output_truncated: false,
         duration_ms: Application.fetch_env!(:ptc_manager, :publisher_slow_gate_ms)
       }}
    end
  end

  setup do
    Process.put(:publisher_test_pid, self())

    previous_test_pid = Application.get_env(:ptc_manager, :publisher_test_pid)
    previous_gate_result = Application.get_env(:ptc_manager, :publisher_gate_result)
    previous_slow_gate_ms = Application.get_env(:ptc_manager, :publisher_slow_gate_ms)

    Application.put_env(:ptc_manager, :publisher_test_pid, self())

    on_exit(fn ->
      restore_env(:publisher_test_pid, previous_test_pid)
      restore_env(:publisher_gate_result, previous_gate_result)
      restore_env(:publisher_slow_gate_ms, previous_slow_gate_ms)
    end)

    :ok
  end

  test "publishes a verified branch once and records the canonical draft PR" do
    {job, publication, result} = verified_publication_fixture()
    Process.put(:publisher_probe_result, {:ok, result})

    remote = %{
      pr_number: 73,
      pr_url: "https://github.com/owner/repo/pull/73",
      head_sha: result.head_sha
    }

    Process.put(:publisher_broker_result, {:ok, remote})
    publication_id = publication.id

    assert {:ok, published} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)

    assert_receive :probe_called
    assert_receive {:gate_called, ^publication_id}
    assert_receive {:broker_called, ^publication_id}
    assert published.state == "published"
    assert published.pr_number == 73
    assert published.pr_url == remote.pr_url
    assert published.remote_head_sha == result.head_sha
    assert Repo.get!(Job, job.id).state == "pr_open"

    gated_job = Repo.get!(Job, job.id)
    assert gated_job.pre_publication_status == "passed"
    assert gated_job.pre_publication_verified_sha == result.head_sha
    assert gated_job.pre_publication_exit_status == 0
    assert gated_job.pre_publication_output == "gate passed"
    assert gated_job.pre_publication_duration_ms == 25
    assert gated_job.pre_publication_verified_at

    assert Repo.aggregate(
             from(audit in AuditEvent,
               where: audit.action == "pr_publication.published"
             ),
             :count
           ) == 1
  end

  test "discovers an agent-created PR only at the exact verified branch and head" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, result} = verified_publication_fixture()
    assert publication.source == "agent"

    worker = worker_fixture(%{worker_key: "agent-publication-worker"})

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "awaiting_pr",
        path: "/tmp/agent-publication-worktree",
        head_sha: result.head_sha,
        herdr_workspace: "agent-publication-workspace",
        last_used_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Process.put(:publisher_discovery_result, {
      :ok,
      %{
        pr_number: 91,
        pr_url: "https://github.com/owner/repo/pull/91",
        state: "open",
        draft: false,
        head_sha: result.head_sha,
        head_ref: publication.branch_name,
        head_repository: base_repository(job),
        base_sha: String.duplicate("d", 40),
        base_ref: "main",
        base_repository: base_repository(job)
      }
    })

    assert {:ok, discovered} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert_receive {:discovery_called, publication_id}
    assert publication_id == publication.id
    assert discovered.state == "published"
    assert discovered.source == "agent"
    assert discovered.pr_number == 91
    assert discovered.remote_head_sha == result.head_sha
    assert Repo.get!(Job, job.id).state == "pr_open"

    allocation = Repo.get!(WorktreeAllocation, allocation.id)
    assert allocation.state == "waiting"
    assert allocation.pr_number == 91

    assert Repo.exists?(
             from audit in AuditEvent,
               where:
                 audit.target_id == ^publication.id and
                   audit.action == "pr_publication.discovered"
           )

    refute_receive :probe_called

    assert {:ok, :empty} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)
  end

  test "adopts an already imported PR into its agent publication" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, result} = verified_publication_fixture()

    external =
      %PrPublication{}
      |> PrPublication.changeset(%{
        repository_id: job.repository_id,
        state: "published",
        idempotency_key: String.duplicate("e", 64),
        fencing_token: 0,
        branch_name: publication.branch_name,
        base_sha: String.duplicate("d", 40),
        head_sha: result.head_sha,
        diff_digest: String.duplicate("f", 64),
        attempt_count: 0,
        pr_number: 91,
        pr_url: "https://github.com/owner/repo/pull/91",
        remote_head_sha: result.head_sha,
        remote_base_sha: String.duplicate("d", 40),
        published_at: DateTime.utc_now(),
        pr_state: "open",
        pr_checked_at: DateTime.utc_now(),
        source: "external",
        title: "Imported before result verification",
        author_login: "agent",
        head_ref: publication.branch_name,
        head_repository: base_repository(job)
      })
      |> Repo.insert!()

    status = %{
      pr_number: 91,
      pr_url: external.pr_url,
      state: "open",
      draft: false,
      head_sha: result.head_sha,
      head_ref: publication.branch_name,
      head_repository: base_repository(job),
      base_sha: String.duplicate("d", 40),
      base_ref: "main",
      base_repository: base_repository(job)
    }

    assert {:ok, adopted} = Publications.record_agent_publication(publication.id, status)
    assert adopted.id == publication.id
    assert adopted.source == "agent"
    assert adopted.job_id == job.id
    assert adopted.pr_number == 91
    assert adopted.state == "published"
    assert Repo.get!(Job, job.id).state == "pr_open"
    refute Repo.get(PrPublication, external.id)

    assert {:ok, replayed} = Publications.record_agent_publication(publication.id, status)
    assert replayed.id == publication.id

    assert Repo.aggregate(
             from(candidate in PrPublication,
               where: candidate.repository_id == ^job.repository_id and candidate.pr_number == 91
             ),
             :count
           ) == 1

    assert Repo.exists?(
             from audit in AuditEvent,
               where:
                 audit.target_id == ^publication.id and
                   audit.action == "pr_publication.external_adopted"
           )
  end

  test "moves external PR history to the stable agent publication id" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, result} = verified_publication_fixture()
    external = external_publication_fixture(job, publication.branch_name, result.head_sha, 95)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, queued_action} =
      Operations.enqueue_agent_action(%{
        repository_id: job.repository_id,
        action_key: "prepare_merge_decision",
        target_type: "pull_request",
        target_id: external.id,
        target_label: "owner/repo#95",
        prompt_version: 1,
        prompt: "Historical external review",
        actor: "maintainer"
      })

    action =
      queued_action
      |> AgentAction.changeset(%{state: "done", ended_at: now})
      |> Repo.update!()

    analysis =
      %PrAnalysis{}
      |> PrAnalysis.changeset(%{
        publication_id: external.id,
        agent_action_id: action.id,
        outcome: "merge-ready",
        plain_summary: "Ready.",
        why_it_matters: "Preserve review history.",
        scope: "small",
        risk: "low",
        technical_evidence: "Reviewed before adoption.",
        base_repository: base_repository(job),
        base_ref: "main",
        reviewed_base_sha: String.duplicate("d", 40),
        head_repository: base_repository(job),
        head_ref: publication.branch_name,
        head_sha: result.head_sha,
        diff_digest: publication.diff_digest,
        analyzed_at: now
      })
      |> Repo.insert!()

    approval =
      %MergeApproval{}
      |> MergeApproval.changeset(%{
        publication_id: external.id,
        pr_analysis_id: analysis.id,
        decision: "approve",
        actor: "maintainer",
        base_repository: base_repository(job),
        base_ref: "main",
        reviewed_base_sha: String.duplicate("d", 40),
        head_sha: result.head_sha,
        diff_digest: publication.diff_digest,
        approved_at: now
      })
      |> Repo.insert!()

    audit =
      %AuditEvent{}
      |> AuditEvent.changeset(%{
        actor: "github-sync",
        action: "pr_publication.external_imported",
        target_type: "pr_publication",
        target_id: external.id,
        details: %{}
      })
      |> Repo.insert!()

    status = agent_status(job, publication, external, result.head_sha, "open")
    assert {:ok, adopted} = Publications.record_agent_publication(publication.id, status)
    assert adopted.id == publication.id
    assert Repo.get!(AgentAction, action.id).target_id == publication.id
    assert Repo.get!(PrAnalysis, analysis.id).publication_id == publication.id
    assert Repo.get!(MergeApproval, approval.id).publication_id == publication.id
    assert Repo.get!(AuditEvent, audit.id).target_id == publication.id
    refute Repo.get(PrPublication, external.id)
  end

  test "defers adoption while an external PR action is active and retries after it finishes" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, result} = verified_publication_fixture()
    external = external_publication_fixture(job, publication.branch_name, result.head_sha, 96)

    {:ok, action} =
      Operations.enqueue_agent_action(%{
        repository_id: job.repository_id,
        action_key: "repair_pr",
        target_type: "pull_request",
        target_id: external.id,
        target_label: "owner/repo#96",
        prompt_version: 1,
        prompt: "Repair using the external checkout.",
        actor: "maintainer"
      })

    status = agent_status(job, publication, external, result.head_sha, "open")
    assert {:ok, deferred} = Publications.record_agent_publication(publication.id, status)
    assert deferred.id == publication.id
    assert deferred.state == "queued"
    assert deferred.last_error =~ "active external action"
    assert Repo.get!(Job, job.id).state == "ready_for_pr"
    assert Repo.get!(PrPublication, external.id).source == "external"
    assert Repo.get!(AgentAction, action.id).target_id == external.id

    action
    |> AgentAction.changeset(%{state: "done", ended_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:ok, adopted} = Publications.record_agent_publication(publication.id, status)
    assert adopted.id == publication.id
    assert adopted.state == "published"
    assert adopted.last_error == nil
    refute Repo.get(PrPublication, external.id)
  end

  @tag sandbox: false
  test "serializes external action enqueue with agent PR adoption on separate connections" do
    database =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-adoption-race-#{System.unique_integer([:positive])}.db"
      )

    File.cp!(Repo.config()[:database], database)

    {:ok, race_repo} =
      Repo.start_link(
        name: nil,
        database: database,
        pool_size: 3,
        pool: DBConnection.ConnectionPool
      )

    Process.unlink(race_repo)
    Repo.put_dynamic_repo(race_repo)

    on_exit(fn ->
      if Process.alive?(race_repo), do: Supervisor.stop(race_repo)
      File.rm(database)
      File.rm(database <> "-shm")
      File.rm(database <> "-wal")
    end)

    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, result} = verified_publication_fixture()

    external =
      job
      |> external_publication_fixture(publication.branch_name, result.head_sha, 97)
      |> PrPublication.changeset(%{checks_state: "failure"})
      |> Repo.update!()

    status = agent_status(job, publication, external, result.head_sha, "open")
    test_pid = self()
    handler_id = "publication-adoption-enqueue-#{System.unique_integer([:positive])}"
    pause_once = :atomics.new(1, signed: false)

    enqueue_task =
      Task.async(fn ->
        Repo.put_dynamic_repo(race_repo)

        receive do
          :start -> MaintainerActions.enqueue("repair_pr", external.id, "maintainer")
        end
      end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:ptc_manager, :repo, :query],
        fn _event, _measurements, metadata, {target_pid, owner_pid, pause_once} ->
          query = Map.get(metadata, :query, "")

          if self() == target_pid and String.contains?(query, "pr_publications") and
               String.contains?(query, "SELECT") and
               :atomics.compare_exchange(pause_once, 1, 0, 1) == :ok do
            send(owner_pid, {:external_publication_loaded, self()})

            receive do
              :continue_enqueue -> :ok
            end
          end
        end,
        {enqueue_task.pid, test_pid, pause_once}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    send(enqueue_task.pid, :start)
    assert_receive {:external_publication_loaded, enqueue_pid}, 1_000

    {:ok, _adoption_pid} =
      Task.start(fn ->
        Repo.put_dynamic_repo(race_repo)
        send(test_pid, :adoption_transaction_starting)

        send(
          test_pid,
          {:adoption_result, Publications.record_agent_publication(publication.id, status)}
        )
      end)

    assert_receive :adoption_transaction_starting, 1_000

    assert_receive {:adoption_result, {:error, :database_busy}}, 5_000

    send(enqueue_pid, :continue_enqueue)

    assert {:ok, action} = Task.await(enqueue_task, 10_000)
    assert action.target_id == external.id

    assert {:ok, deferred} = Publications.record_agent_publication(publication.id, status)
    assert deferred.id == publication.id
    assert deferred.state == "queued"
    assert Repo.get!(PrPublication, external.id).source == "external"
  end

  test "consolidates an imported repaired head after the PR has merged" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, _result} = verified_publication_fixture()
    repaired_head = String.duplicate("9", 40)

    external =
      external_publication_fixture(job, publication.branch_name, repaired_head, 93)

    status = agent_status(job, publication, external, repaired_head, "merged")

    assert {:ok, merged} = Publications.record_agent_publication(publication.id, status)
    assert merged.id == publication.id
    assert merged.source == "agent"
    assert merged.state == "published"
    assert merged.pr_state == "merged"
    assert merged.remote_head_sha == repaired_head
    assert merged.last_error == nil
    assert Repo.get!(Job, job.id).state == "done"
    refute Repo.get(PrPublication, external.id)

    assert Repo.aggregate(
             from(candidate in PrPublication,
               where: candidate.repository_id == ^job.repository_id and candidate.pr_number == 93
             ),
             :count
           ) == 1
  end

  test "records an agent PR that was merged before its first discovery" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, result} = verified_publication_fixture()

    status = %{
      pr_number: 94,
      pr_url: "https://github.com/owner/repo/pull/94",
      state: "merged",
      draft: false,
      head_sha: result.head_sha,
      head_ref: publication.branch_name,
      head_repository: base_repository(job),
      base_sha: String.duplicate("d", 40),
      base_ref: "main",
      base_repository: base_repository(job)
    }

    assert {:ok, merged} = Publications.record_agent_publication(publication.id, status)
    assert merged.state == "published"
    assert merged.pr_state == "merged"
    assert Repo.get!(Job, job.id).state == "done"
  end

  test "blocks an agent-created PR whose head does not match the verified commit" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, _result} = verified_publication_fixture()

    Process.put(:publisher_discovery_result, {
      :ok,
      %{
        pr_number: 92,
        pr_url: "https://github.com/owner/repo/pull/92",
        state: "open",
        draft: false,
        head_sha: String.duplicate("e", 40),
        head_ref: publication.branch_name,
        head_repository: base_repository(job),
        base_sha: String.duplicate("d", 40),
        base_ref: "main",
        base_repository: base_repository(job)
      }
    })

    assert {:ok, blocked} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert blocked.state == "blocked"
    assert blocked.last_error =~ "head commit"
    assert Repo.get!(Job, job.id).state == "publish_blocked"
  end

  test "a missing agent PR is delayed without starving existing PR status" do
    {open_job, open_publication, open_result} = published_publication_fixture()

    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {_agent_job, agent_publication, _agent_result} = verified_publication_fixture()

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "open",
        pr_url: open_publication.pr_url,
        head_sha: open_result.head_sha,
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(open_job)
      }
    })

    Process.put(:publisher_discovery_result, {:retry, :agent_pull_request_not_found})

    assert {:retry_after, 60_000} =
             PublicationStatusReconciler.run_once(client: FakeBroker)

    assert_receive {:status_called, status_publication_id}
    assert status_publication_id == open_publication.id
    assert_receive {:discovery_called, discovery_publication_id}
    assert discovery_publication_id == agent_publication.id

    delayed = Repo.get!(PrPublication, agent_publication.id)
    assert delayed.state == "queued"
    assert delayed.next_attempt_at
    assert delayed.last_error =~ "agent_pull_request_not_found"
    assert Publications.next_agent_for_discovery() == nil
  end

  test "retry wakes agent discovery after agent publication mode is disabled" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {job, publication, _result} = verified_publication_fixture()
    assert publication.source == "agent"

    assert {:ok, blocked} = Publications.block_agent_discovery(publication.id, :needs_retry)
    assert blocked.state == "blocked"
    assert Repo.get!(Job, job.id).state == "publish_blocked"

    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, false)
    assert {:ok, retried} = Publications.retry_blocked(publication.id, "andreas")
    assert retried.state == "queued"
    assert Publications.agent_reconciliation_needed?()

    assert {:noreply, %{timer_ref: nil}} =
             PublicationStatusPoller.handle_cast(:wake, %{task_ref: nil, timer_ref: nil})

    assert_receive :reconcile_pr
  end

  test "a transient broker failure stays queued with bounded backoff" do
    {job, publication, result} = verified_publication_fixture()
    Process.put(:publisher_probe_result, {:ok, result})
    Process.put(:publisher_broker_result, {:retry, :offline})

    assert {:error, :offline} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)

    queued = Repo.get!(PrPublication, publication.id)
    assert queued.state == "queued"
    assert queued.attempt_count == 1
    assert queued.next_attempt_at
    assert queued.last_error =~ "offline"
    assert Repo.get!(Job, job.id).state == "ready_for_pr"

    assert {:ok, :empty} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)
  end

  test "a GitHub rate limit honors its delay without consuming the retry budget" do
    {job, publication, result} = verified_publication_fixture()
    Process.put(:publisher_probe_result, {:ok, result})

    rate_limit = {:github_http_error, 403, "API rate limit exceeded", 3_600_000}
    Process.put(:publisher_broker_result, {:retry, {:after, 3_600_000, rate_limit}})

    previous_max = Application.get_env(:ptc_manager, :publication_max_attempts)
    Application.put_env(:ptc_manager, :publication_max_attempts, 1)
    on_exit(fn -> Application.put_env(:ptc_manager, :publication_max_attempts, previous_max) end)

    before = DateTime.utc_now()

    assert {:error, {:after, 3_600_000, ^rate_limit}} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)

    queued = Repo.get!(PrPublication, publication.id)
    assert queued.state == "queued"
    assert queued.attempt_count == 0
    assert DateTime.diff(queued.next_attempt_at, before, :second) >= 3_599
    assert Repo.get!(Job, job.id).state == "ready_for_pr"
  end

  test "a changed branch blocks before the credential-bearing broker runs" do
    {job, publication, result} = verified_publication_fixture()

    Process.put(
      :publisher_probe_result,
      {:ok, %{result | head_sha: String.duplicate("d", 40)}}
    )

    assert {:error, :verified_branch_changed} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)

    assert_receive :probe_called
    refute_receive {:broker_called, _publication_id}
    assert Repo.get!(PrPublication, publication.id).state == "blocked"
    assert Repo.get!(Job, job.id).state == "publish_blocked"
  end

  test "a failing pre-publication command blocks before the credential-bearing broker runs" do
    {job, publication, result} = verified_publication_fixture()
    publication_id = publication.id
    Process.put(:publisher_probe_result, {:ok, result})

    Application.put_env(
      :ptc_manager,
      :publisher_gate_result,
      {:ok,
       %{
         status: "failed",
         verified_sha: result.head_sha,
         config_digest: job.pre_publication_config_digest,
         exit_status: 7,
         output: "dialyzer failed",
         output_truncated: false,
         duration_ms: 321
       }}
    )

    assert {:error, :pre_publication_gate_failed} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)

    assert_receive {:gate_called, ^publication_id}
    refute_receive {:broker_called, _publication_id}

    failed = Repo.get!(Job, job.id)
    assert failed.state == "publish_blocked"
    assert failed.pre_publication_status == "failed"
    assert failed.pre_publication_verified_sha == result.head_sha
    assert failed.pre_publication_exit_status == 7
    assert failed.pre_publication_output == "dialyzer failed"
  end

  test "renews the fenced publication claim while a slow gate is running" do
    {_job, publication, result} = verified_publication_fixture()
    Process.put(:publisher_probe_result, {:ok, result})

    remote = %{
      pr_number: 74,
      pr_url: "https://github.com/owner/repo/pull/74",
      head_sha: result.head_sha
    }

    Process.put(:publisher_broker_result, {:ok, remote})

    previous_claim_timeout =
      Application.get_env(:ptc_manager, :publication_claim_timeout_ms)

    previous_renewal_interval =
      Application.get_env(:ptc_manager, :publication_gate_renewal_interval_ms)

    Application.put_env(:ptc_manager, :publication_claim_timeout_ms, 40)
    Application.put_env(:ptc_manager, :publication_gate_renewal_interval_ms, 5)
    Application.put_env(:ptc_manager, :publisher_slow_gate_ms, 120)

    on_exit(fn ->
      restore_env(:publication_claim_timeout_ms, previous_claim_timeout)
      restore_env(:publication_gate_renewal_interval_ms, previous_renewal_interval)
    end)

    assert {:ok, published} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: SlowGate)

    assert_receive {:slow_gate_started, publication_id}
    assert publication_id == publication.id
    assert_receive {:broker_called, ^publication_id}
    assert published.state == "published"
    assert Repo.get!(Job, published.job_id).pre_publication_output == "slow gate passed"
  end

  test "an expired publication attempt is reclaimed and fences the old result" do
    {_job, publication, result} = verified_publication_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, first} = Publications.claim(publication.id, now)
    assert {:ok, second} = Publications.claim(publication.id, DateTime.add(now, 181, :second))
    refute first.attempt_token == second.attempt_token

    remote = %{
      pr_number: 73,
      pr_url: "https://github.com/owner/repo/pull/73",
      head_sha: result.head_sha
    }

    assert {:error, :stale_publication_attempt} =
             Publications.complete(
               publication.id,
               publication.fencing_token,
               first.attempt_token,
               remote
             )

    assert Repo.get!(PrPublication, publication.id).attempt_token == second.attempt_token
  end

  test "expired publication attempts stop at the configured retry budget" do
    {job, publication, _result} = verified_publication_fixture()
    previous_max = Application.get_env(:ptc_manager, :publication_max_attempts)
    Application.put_env(:ptc_manager, :publication_max_attempts, 1)
    on_exit(fn -> Application.put_env(:ptc_manager, :publication_max_attempts, previous_max) end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, _claimed} = Publications.claim(publication.id, now)

    assert {:error, :publication_attempts_exhausted} =
             Publications.claim(publication.id, DateTime.add(now, 181, :second))

    blocked = Repo.get!(PrPublication, publication.id)
    assert blocked.state == "blocked"
    assert blocked.attempt_count == 1
    assert Repo.get!(Job, job.id).state == "publish_blocked"
  end

  test "a maintainer can requeue a blocked publication without duplicating it" do
    {job, publication, result} = verified_publication_fixture()
    Process.put(:publisher_probe_result, {:ok, result})
    Process.put(:publisher_broker_result, {:blocked, :github_app_not_configured})

    assert {:error, :github_app_not_configured} =
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker, gate: FakeGate)

    assert {:ok, queued} = Publications.retry_blocked(publication.id, "andreas")
    assert queued.state == "queued"
    assert Repo.get!(Job, job.id).state == "ready_for_pr"
    assert Repo.aggregate(PrPublication, :count) == 1
  end

  test "result verification creates one immutable publication identity" do
    {job, publication, result} = verified_publication_fixture()

    assert publication.idempotency_key =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, _job} =
             Operations.mark_result_verified(
               job.id,
               job.fencing_token,
               job.result_attempt_token,
               result,
               contract()
             )

    assert Repo.aggregate(PrPublication, :count) == 1
  end

  test "merged and closed PRs leave the active implementation queue" do
    {merged_job, _publication, result} = published_publication_fixture()

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "merged",
        pr_url: "https://github.com/owner/repo/pull/73",
        head_sha: result.head_sha,
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(merged_job)
      }
    })

    assert {:ok, merged} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert merged.pr_state == "merged"
    assert Repo.get!(Job, merged_job.id).state == "done"

    {closed_job, _publication, closed_result} = published_publication_fixture()

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "closed",
        pr_url: "https://github.com/owner/repo/pull/73",
        head_sha: closed_result.head_sha,
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(closed_job)
      }
    })

    assert {:ok, closed} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert closed.pr_state == "closed"
    assert Repo.get!(Job, closed_job.id).state == "cancelled"
  end

  test "a merged PR with a later repaired head leaves the blocked lane" do
    {job, publication, _result} = published_publication_fixture()
    repaired_head = String.duplicate("e", 40)

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "merged",
        pr_url: publication.pr_url,
        head_sha: repaired_head,
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(job)
      }
    })

    assert {:ok, merged} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert merged.state == "published"
    assert merged.pr_state == "merged"
    assert merged.remote_head_sha == repaired_head
    assert merged.last_error == nil

    terminal_job = Repo.get!(Job, job.id)
    assert terminal_job.state == "done"
    assert terminal_job.last_error == nil
  end

  test "terminal PR reconciliation cannot overwrite an active cleanup claim" do
    {job, publication, result} = published_publication_fixture()
    worker = worker_fixture(%{worker_key: "cleanup-race"})

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "terminal",
        path: "/tmp/cleanup-race",
        head_sha: result.head_sha,
        last_used_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert {:ok, _claimed, _token} = Operations.claim_worktree_cleanup(allocation.id)

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "merged",
        pr_url: publication.pr_url,
        head_sha: result.head_sha,
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(job)
      }
    })

    assert {:ok, _merged} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "cleaning"
  end

  test "canonical open PR status retains a warm worktree in waiting state" do
    {job, publication, result} = published_publication_fixture()
    worker = worker_fixture(%{worker_key: "open-pr-worker"})

    allocation =
      %WorktreeAllocation{}
      |> WorktreeAllocation.changeset(%{
        worker_id: worker.id,
        job_id: job.id,
        state: "warm",
        path: "/tmp/open-pr-worktree",
        head_sha: result.head_sha,
        herdr_workspace: "open-pr-workspace",
        last_used_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "open",
        pr_url: publication.pr_url,
        head_sha: result.head_sha,
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(job)
      }
    })

    assert {:ok, _open} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert Repo.get!(WorktreeAllocation, allocation.id).state == "waiting"
  end

  test "a changed GitHub PR head blocks the publication lineage" do
    {job, publication, _result} = published_publication_fixture()

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "open",
        pr_url: "https://github.com/owner/repo/pull/73",
        head_sha: String.duplicate("e", 40),
        base_sha: String.duplicate("a", 40),
        base_ref: "main",
        base_repository: base_repository(job)
      }
    })

    assert {:ok, blocked} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert blocked.id == publication.id
    assert blocked.state == "blocked"
    assert Repo.get!(Job, job.id).state == "publish_blocked"
  end

  test "an explicitly verified repair advances the trusted PR head" do
    {job, publication, _result} = published_publication_fixture()
    repaired_head = String.duplicate("e", 40)

    remote = %{
      state: "open",
      pr_number: publication.pr_number,
      pr_url: publication.pr_url,
      head_sha: repaired_head,
      head_ref: publication.branch_name,
      head_repository: base_repository(job),
      base_sha: String.duplicate("d", 40),
      base_ref: "main",
      base_repository: base_repository(job),
      draft: false,
      checks_state: "pending",
      checks_total: 2,
      checks_failed: 0,
      checks_pending: 2,
      mergeability: "unknown",
      mergeable_state: "unknown"
    }

    verified = %{
      base_sha: String.duplicate("a", 40),
      head_sha: repaired_head,
      diff_digest: String.duplicate("f", 64),
      commit_count: 3
    }

    assert {:ok, prematurely_blocked} =
             Publications.record_remote_status(publication.id, remote)

    assert prematurely_blocked.state == "blocked"
    assert Repo.get!(Job, job.id).state == "publish_blocked"

    assert {:ok, repaired} =
             Publications.record_repaired_status(publication.id, remote, verified)

    assert repaired.state == "published"
    assert repaired.remote_head_sha == repaired_head
    assert repaired.head_sha == repaired_head
    assert repaired.diff_digest == verified.diff_digest
    assert repaired.checks_state == "pending"

    repaired_job = Repo.get!(Job, job.id)
    assert repaired_job.state == "pr_open"
    assert repaired_job.result_head_sha == repaired_head
    assert repaired_job.result_diff_digest == verified.diff_digest
  end

  test "a changed GitHub PR base blocks the publication lineage" do
    {job, publication, result} = published_publication_fixture()

    Process.put(:publisher_status_result, {
      :ok,
      %{
        state: "open",
        pr_url: "https://github.com/owner/repo/pull/73",
        head_sha: result.head_sha,
        base_sha: String.duplicate("a", 40),
        base_ref: "release",
        base_repository: "owner/repo"
      }
    })

    assert {:ok, blocked} = PublicationStatusReconciler.run_once(client: FakeBroker)
    assert blocked.id == publication.id
    assert blocked.state == "blocked"
    assert blocked.last_error =~ "base"
    assert Repo.get!(Job, job.id).state == "publish_blocked"
  end

  test "PR status rate limits delay the status poller" do
    {_job, publication, _result} = published_publication_fixture()

    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    {_agent_job, _agent_publication, _agent_result} = verified_publication_fixture()

    reason = {:after, 3_600_000, {:github_http_error, 403, "rate limit", 3_600_000}}
    Process.put(:publisher_status_result, {:retry, reason})

    assert {:retry_after, 3_600_000} =
             PublicationStatusReconciler.run_once(client: FakeBroker)

    assert Repo.get!(PrPublication, publication.id).last_error =~ "rate limit"
    refute_receive {:discovery_called, _publication_id}
    assert PublicationStatusPoller.next_delay({:retry_after, 3_600_000}) == 3_600_000

    assert PublicationStatusReconciler.combine_results(
             {:retry_after, 3_600_000},
             {:retry_after, 60_000}
           ) == {:retry_after, 3_600_000}
  end

  test "a publication claim is renewed before remote mutation" do
    {_job, publication, _result} = verified_publication_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, claimed} = Publications.claim(publication.id, now)

    assert :ok =
             Publications.renew_claim(
               claimed.id,
               claimed.fencing_token,
               claimed.attempt_token,
               DateTime.add(now, 10, :second)
             )

    renewed = Repo.get!(PrPublication, publication.id)
    assert DateTime.compare(renewed.attempt_expires_at, claimed.attempt_expires_at) == :gt
  end

  test "the GitHub App broker rejects a non-job branch before reading credentials" do
    {_job, publication, _result} = verified_publication_fixture()
    publication = Repo.preload(publication, job: [:issue, :repository])

    settings =
      for key <- [
            :github_app_id,
            :github_app_installation_id,
            :github_app_private_key_path,
            :github_push_timeout_binary,
            :github_publish_staging_root
          ],
          into: %{} do
        {key, Application.get_env(:ptc_manager, key)}
      end

    on_exit(fn ->
      Enum.each(settings, fn {key, value} -> Application.put_env(:ptc_manager, key, value) end)
    end)

    Application.put_env(:ptc_manager, :github_app_id, "1")
    Application.put_env(:ptc_manager, :github_app_installation_id, "2")
    Application.put_env(:ptc_manager, :github_app_private_key_path, "/does/not/exist")
    Application.put_env(:ptc_manager, :github_push_timeout_binary, "/usr/bin/timeout")
    Application.put_env(:ptc_manager, :github_publish_staging_root, System.tmp_dir!())

    assert {:blocked, :unexpected_job_branch} =
             PtcManager.GitHub.AppBroker.publish(%{
               publication
               | branch_name: "someone-else/unsafe"
             })
  end

  test "the GitHub App broker rejects an exact job branch without matching gate evidence" do
    {_job, publication, _result} = verified_publication_fixture()
    publication = Repo.preload(publication, [job: [:issue, :repository]], force: true)

    settings =
      for key <- [
            :github_app_id,
            :github_app_installation_id,
            :github_app_private_key_path,
            :github_push_timeout_binary,
            :github_publish_staging_root
          ],
          into: %{} do
        {key, Application.get_env(:ptc_manager, key)}
      end

    on_exit(fn ->
      Enum.each(settings, fn {key, value} -> Application.put_env(:ptc_manager, key, value) end)
    end)

    Application.put_env(:ptc_manager, :github_app_id, "1")
    Application.put_env(:ptc_manager, :github_app_installation_id, "2")
    Application.put_env(:ptc_manager, :github_app_private_key_path, "/does/not/exist")
    Application.put_env(:ptc_manager, :github_push_timeout_binary, "/usr/bin/timeout")
    Application.put_env(:ptc_manager, :github_publish_staging_root, System.tmp_dir!())

    assert {:blocked, :pre_publication_gate_not_passed} =
             PtcManager.GitHub.AppBroker.publish(publication)
  end

  test "the broker copies the bounded final-commit retrospective into its PR body" do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-retrospective-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "Agent"])
    git!(path, ["config", "user.email", "agent@example.test"])
    File.write!(Path.join(path, "README.md"), "retrospective test\n")
    git!(path, ["add", "README.md"])

    git!(path, [
      "commit",
      "-m",
      "Implement the bounded change",
      "-m",
      "PTC-AGENT-RETROSPECTIVE-BEGIN\nA flaky retry test surprised me.\nPTC-AGENT-RETROSPECTIVE-END"
    ])

    previous_timeout = Application.get_env(:ptc_manager, :github_push_timeout_binary)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :github_push_timeout_binary, previous_timeout)
    end)

    Application.put_env(:ptc_manager, :github_push_timeout_binary, timeout_binary!())
    head_sha = git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    retrospective = PtcManager.GitHub.AppBroker.agent_retrospective(path, head_sha)
    assert retrospective == "A flaky retry test surprised me."

    body = PtcManager.GitHub.AppBroker.pull_request_body(42, retrospective)
    assert body =~ "## Agent retrospective"
    assert body =~ retrospective
  end

  test "trusted staging does not inherit worker-controlled Git configuration" do
    unique = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "ptc-manager-broker-test-#{unique}")
    source_path = Path.join(test_root, "worker")
    staging_root = Path.join(test_root, "staging")

    File.mkdir_p!(source_path)
    File.mkdir_p!(staging_root)
    File.chmod!(staging_root, 0o700)
    on_exit(fn -> File.rm_rf(test_root) end)

    stale_path = Path.join(staging_root, "ptc-manager-publish-stale")
    fresh_path = Path.join(staging_root, "ptc-manager-publish-fresh")
    File.mkdir!(stale_path)
    File.mkdir!(fresh_path)
    File.touch!(stale_path, System.os_time(:second) - 7_200)

    git!(source_path, ["init", "--initial-branch=main"])
    git!(source_path, ["config", "user.name", "Worker"])
    git!(source_path, ["config", "user.email", "worker@example.test"])
    File.write!(Path.join(source_path, "README.md"), "trusted staging test\n")
    git!(source_path, ["add", "README.md"])
    git!(source_path, ["commit", "-m", "initial"])
    git!(source_path, ["checkout", "-b", "ptc-manager/issue-1-job-1"])
    head_sha = git!(source_path, ["rev-parse", "HEAD"]) |> String.trim()

    git!(source_path, [
      "config",
      "url.file:///worker-controlled/.insteadOf",
      "https://github.com/"
    ])

    previous_root = Application.get_env(:ptc_manager, :github_publish_staging_root)
    previous_timeout = Application.get_env(:ptc_manager, :github_push_timeout_binary)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :github_publish_staging_root, previous_root)
      Application.put_env(:ptc_manager, :github_push_timeout_binary, previous_timeout)
    end)

    Application.put_env(:ptc_manager, :github_publish_staging_root, staging_root)
    Application.put_env(:ptc_manager, :github_push_timeout_binary, timeout_binary!())

    assert {:ok, staged_config} =
             PtcManager.GitHub.AppBroker.inspect_staged_repository(
               source_path,
               %{branch_name: "ptc-manager/issue-1-job-1", head_sha: head_sha},
               fn staged_path -> File.read(Path.join(staged_path, "config")) end
             )

    refute staged_config =~ "worker-controlled"
    refute staged_config =~ "insteadOf"
    refute File.exists?(stale_path)
    assert File.dir?(fresh_path)
  end

  defp verified_publication_fixture do
    repository = repository_fixture(%{local_path: "/tmp/repository"})

    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job =
      job
      |> Job.changeset(%{
        state: "awaiting_reconciliation",
        fencing_token: 1,
        branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}",
        publication_source:
          if(Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false),
            do: "agent",
            else: "broker"
          )
      })
      |> Repo.update!()

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 2
    }

    assert {:ok, claimed} = Operations.claim_result_job(job.id)

    assert {:ok, verified} =
             Operations.mark_result_verified(
               claimed.id,
               claimed.fencing_token,
               claimed.result_attempt_token,
               result,
               contract()
             )

    publication =
      Repo.get_by!(PrPublication, job_id: job.id)
      |> PrPublication.changeset(%{next_attempt_at: DateTime.utc_now()})
      |> Repo.update!()

    {verified, publication, result}
  end

  defp contract, do: PtcManager.RepositoryContractFixture.contract()

  defp external_publication_fixture(job, branch, head_sha, pr_number) do
    %PrPublication{}
    |> PrPublication.changeset(%{
      repository_id: job.repository_id,
      state: "published",
      idempotency_key:
        :crypto.hash(:sha256, "external-publication-#{job.id}-#{pr_number}")
        |> Base.encode16(case: :lower),
      fencing_token: 0,
      branch_name: branch,
      base_sha: String.duplicate("d", 40),
      head_sha: head_sha,
      diff_digest: String.duplicate("f", 64),
      attempt_count: 0,
      pr_number: pr_number,
      pr_url: "https://github.com/owner/repo/pull/#{pr_number}",
      remote_head_sha: head_sha,
      remote_base_sha: String.duplicate("d", 40),
      published_at: DateTime.utc_now(),
      pr_state: "open",
      pr_checked_at: DateTime.utc_now(),
      source: "external",
      title: "Imported before result verification",
      author_login: "agent",
      head_ref: branch,
      head_repository: base_repository(job)
    })
    |> Repo.insert!()
  end

  defp agent_status(job, publication, external, head_sha, state) do
    %{
      pr_number: external.pr_number,
      pr_url: external.pr_url,
      state: state,
      draft: false,
      head_sha: head_sha,
      head_ref: publication.branch_name,
      head_repository: base_repository(job),
      base_sha: String.duplicate("d", 40),
      base_ref: "main",
      base_repository: base_repository(job)
    }
  end

  defp published_publication_fixture do
    {job, publication, result} = verified_publication_fixture()
    assert {:ok, claimed} = Publications.claim(publication.id)

    assert {:ok, published} =
             Publications.complete(
               claimed.id,
               claimed.fencing_token,
               claimed.attempt_token,
               %{
                 pr_number: 73,
                 pr_url: "https://github.com/owner/repo/pull/73",
                 head_sha: result.head_sha
               }
             )

    {Repo.get!(Job, job.id), published, result}
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end

  defp timeout_binary! do
    System.find_executable("timeout") || raise "timeout executable is required for this test"
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)

  defp base_repository(job) do
    repository = Repo.get!(Repository, job.repository_id)
    "#{repository.github_owner}/#{repository.github_name}"
  end
end
