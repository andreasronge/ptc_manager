defmodule PtcManager.PublisherTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AuditEvent,
    Job,
    PrPublication,
    Repository,
    WorktreeAllocation
  }

  alias PtcManager.{
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

  setup do
    Process.put(:publisher_test_pid, self())
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

    assert {:ok, published} = Publisher.run_once(probe: FakeProbe, broker: FakeBroker)
    assert_receive :probe_called
    assert_receive {:broker_called, publication_id}
    assert publication_id == publication.id
    assert published.state == "published"
    assert published.pr_number == 73
    assert published.pr_url == remote.pr_url
    assert published.remote_head_sha == result.head_sha
    assert Repo.get!(Job, job.id).state == "pr_open"

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
    assert {:ok, :empty} = Publisher.run_once(probe: FakeProbe, broker: FakeBroker)
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

    assert {:error, :offline} = Publisher.run_once(probe: FakeProbe, broker: FakeBroker)

    queued = Repo.get!(PrPublication, publication.id)
    assert queued.state == "queued"
    assert queued.attempt_count == 1
    assert queued.next_attempt_at
    assert queued.last_error =~ "offline"
    assert Repo.get!(Job, job.id).state == "ready_for_pr"
    assert {:ok, :empty} = Publisher.run_once(probe: FakeProbe, broker: FakeBroker)
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
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker)

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
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker)

    assert_receive :probe_called
    refute_receive {:broker_called, _publication_id}
    assert Repo.get!(PrPublication, publication.id).state == "blocked"
    assert Repo.get!(Job, job.id).state == "publish_blocked"
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
             Publisher.run_once(probe: FakeProbe, broker: FakeBroker)

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
               result
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
               result
             )

    publication =
      Repo.get_by!(PrPublication, job_id: job.id)
      |> PrPublication.changeset(%{next_attempt_at: DateTime.utc_now()})
      |> Repo.update!()

    {verified, publication, result}
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

  defp base_repository(job) do
    repository = Repo.get!(Repository, job.repository_id)
    "#{repository.github_owner}/#{repository.github_name}"
  end
end
