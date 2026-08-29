defmodule PtcManager.DispatchTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Dispatch
  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentRun, AuditEvent, Job}
  alias PtcManager.Repo

  defmodule FakeGitHub do
    @behaviour PtcManager.GitHub
    def list_open_issues(_repository), do: {:ok, []}
    def get_issue(_repository, _number), do: Process.get(:dispatch_github_result)
  end

  defmodule FakeAdapter do
    @behaviour PtcManager.Dispatch.Adapter

    def dispatch(context) do
      send(Process.get(:dispatch_test_pid), {:dispatch_context, context})
      Process.get(:dispatch_adapter_result)
    end

    def remove_worktree(_allocation), do: :ok
  end

  setup do
    Process.put(:dispatch_test_pid, self())

    {:ok, _worker} =
      Operations.create_worker(%{
        worker_key: "herdr:default",
        name: "Herdr default",
        status: "online",
        capabilities: %{"herdr" => true, "implementation_slots" => 1}
      })

    Process.put(
      :dispatch_adapter_result,
      {:ok,
       %{
         workspace_id: "w-job",
         pane_id: "w-job:p1",
         session: "default",
         external_key: "default:w-job:p1"
       }}
    )

    :ok
  end

  test "leaves work queued when the synchronized worker is degraded" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    worker = Repo.get_by!(Operations.Worker, worker_key: "herdr:default")
    worker |> Operations.Worker.changeset(%{status: "degraded"}) |> Repo.update!()

    assert {:error, :worker_unavailable} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "fresh approved work is leased once and attached to a fenced Herdr attempt" do
    {repository, issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})

    assert {:ok, %{job: working, run: run}} =
             Dispatch.run_once(
               github: FakeGitHub,
               adapter: FakeAdapter,
               worker_key: "herdr:default",
               lease_ms: 60_000
             )

    assert_receive {:dispatch_context, %{job: leased}}
    assert leased.id == job.id
    assert leased.state == "starting"
    assert leased.fencing_token == 1
    assert leased.branch_name == "ptc-manager/issue-#{issue.number}-job-#{job.id}"
    assert leased.publication_source == "broker"

    assert working.state == "working"
    assert working.repository_id == repository.id
    assert run.job_id == job.id
    assert run.fencing_token == 1
    assert run.herdr_workspace == "w-job"
    assert run.herdr_pane == "w-job:p1"
    assert Repo.aggregate(AgentRun, :count) == 1

    actions = Repo.all(from audit in AuditEvent, select: audit.action)
    assert "job.leased" in actions
    assert "job.started" in actions
  end

  test "a changed GitHub issue cancels the stale approval before dispatch" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    changed = Map.put(remote, "title", "Changed after approval")
    Process.put(:dispatch_github_result, {:ok, changed})

    assert {:error, :stale_approval} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    refute_receive {:dispatch_context, _context}
    rejected = Repo.get!(Job, job.id)
    assert rejected.state == "cancelled"
    assert rejected.fencing_token == 0
    assert rejected.last_error == "stale_approval"
  end

  test "a GitHub read failure leaves the approved job queued" do
    {_repository, _issue, _proposal, job, _remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:error, :offline})

    assert {:error, :offline} = Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)
    assert Repo.get!(Job, job.id).state == "queued"
    refute_receive {:dispatch_context, _context}
  end

  test "an ambiguous Herdr launch failure blocks retries pending reconciliation" do
    {repository, _issue, _proposal, job, remote} = approved_job_fixture()
    Process.put(:dispatch_github_result, {:ok, remote})
    Process.put(:dispatch_adapter_result, {:error, :agent_not_ready})

    assert {:error, :agent_not_ready} =
             Dispatch.run_once(github: FakeGitHub, adapter: FakeAdapter)

    uncertain = Repo.get!(Job, job.id)
    assert uncertain.state == "reconciling"
    assert uncertain.fencing_token == 1
    assert uncertain.last_error =~ "agent_not_ready"
    refute uncertain.ended_at

    second_remote = remote_issue(System.unique_integer([:positive]))

    second_issue =
      issue_fixture(repository, IssueSnapshot.normalize!(second_remote, repository.id))

    proposal_fixture(second_issue)
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "andreas")

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(second_remote, repository.id),
               60_000
             )

    assert Repo.get!(Job, second_job.id).state == "queued"

    job
    |> Job.changeset(%{state: "idle"})
    |> Repo.update!()

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(second_remote, repository.id),
               60_000
             )
  end

  test "a second lease contender cannot cancel the first lease" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    canonical = IssueSnapshot.normalize!(remote, job.repository_id)

    assert {:ok, leased} = Operations.lease_job(job.id, "herdr:default", canonical, 60_000)

    assert {:error, :already_leased} =
             Operations.lease_job(job.id, "herdr:default", canonical, 60_000)

    current = Repo.get!(Job, job.id)
    assert current.state == "starting"
    assert current.fencing_token == leased.fencing_token
  end

  test "transactional capacity leaves additional approved work queued" do
    {repository, _issue, _proposal, first_job, first_remote} = approved_job_fixture()
    second_remote = remote_issue(System.unique_integer([:positive]))

    second_issue =
      issue_fixture(repository, IssueSnapshot.normalize!(second_remote, repository.id))

    proposal_fixture(second_issue)
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "andreas")

    assert {:ok, _leased} =
             Operations.lease_job(
               first_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(first_remote, repository.id),
               60_000
             )

    assert {:error, :dispatch_capacity} =
             Operations.lease_job(
               second_job.id,
               "herdr:default",
               IssueSnapshot.normalize!(second_remote, repository.id),
               60_000
             )

    assert Repo.get!(Job, second_job.id).state == "queued"
  end

  test "an expired lease stays active for reconciliation instead of enabling a duplicate" do
    {_repository, _issue, _proposal, job, remote} = approved_job_fixture()
    canonical = IssueSnapshot.normalize!(remote, job.repository_id)
    assert {:ok, leased} = Operations.lease_job(job.id, "herdr:default", canonical, 1)

    later = DateTime.add(leased.lease_expires_at, 1, :second)
    assert Operations.expire_job_leases(later) == 1

    reconciling = Repo.get!(Job, job.id)
    assert reconciling.state == "reconciling"
    assert {:error, :already_active} = Operations.approve_issue(job.issue_id, "andreas")
  end

  test "decodes the documented Herdr worktree response" do
    output =
      Jason.encode!(%{
        "result" => %{
          "workspace" => %{"workspace_id" => "w12"},
          "root_pane" => %{"pane_id" => "w12:p1"}
        }
      })

    assert {:ok, "w12", "w12:p1"} = PtcManager.Dispatch.HerdrAdapter.decode_worktree(output)
  end

  test "agent startup may outlive the generic Herdr command timeout" do
    unique = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "ptc-manager-slow-herdr-#{unique}")
    repository_path = Path.join(test_root, "repository")
    fake_herdr = Path.join(test_root, "herdr")

    File.mkdir_p!(repository_path)

    File.write!(
      fake_herdr,
      """
      #!/bin/sh
      case "$*" in
        *"worktree create"*)
          printf '%s' '{"result":{"workspace":{"workspace_id":"w-slow"},"root_pane":{"pane_id":"w-slow:p1"}}}'
          ;;
        *"agent start"*)
          sleep 1
          printf '%s' '{"result":{"agent":{"agent_session":{"value":"impl-slow"}}}}'
          ;;
        *"agent prompt"*)
          printf '%s' '{"result":{}}'
          ;;
        *)
          exit 2
          ;;
      esac
      """
    )

    File.chmod!(fake_herdr, 0o700)

    keys = [
      :dispatch_enabled,
      :herdr_binary,
      :herdr_run_as_user,
      :herdr_timeout_ms,
      :implementation_agent_start_timeout_ms
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)

      File.rm_rf!(test_root)
    end)

    Application.put_env(:ptc_manager, :herdr_binary, fake_herdr)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.delete_env(:ptc_manager, :herdr_run_as_user)
    Application.put_env(:ptc_manager, :herdr_timeout_ms, 500)
    Application.put_env(:ptc_manager, :implementation_agent_start_timeout_ms, 1_500)

    repository = repository_fixture(%{local_path: repository_path})
    remote = remote_issue(unique)
    issue = issue_fixture(repository, IssueSnapshot.normalize!(remote, repository.id))
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    assert {:ok, leased} =
             Operations.lease_job(
               job.id,
               "herdr:default",
               IssueSnapshot.normalize!(remote, repository.id),
               60_000
             )

    assert {:ok, dispatch} =
             PtcManager.Dispatch.HerdrAdapter.dispatch(%{
               job: leased,
               issue: leased.issue,
               repository: leased.repository
             })

    assert dispatch.workspace_id == "w-slow"
    assert dispatch.pane_id == "w-slow:p1"
    assert dispatch.external_key == "default:impl-slow"
  end

  test "builds the configurable test, prompt-only review, and broker contract" do
    repository =
      repository_fixture(%{
        required_pre_pr_reviews: 2,
        implementation_test_command: "mix precommit"
      })

    issue = issue_fixture(repository, %{number: 42, title: "Fix the queue"})
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job =
      job
      |> Job.changeset(%{branch_name: "ptc-manager/issue-42-job-#{job.id}", fencing_token: 3})
      |> Repo.update!()

    prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(repository, issue, job)

    assert prompt =~ "Fix GitHub issue #42"
    assert prompt =~ "Run this configured test command exactly: mix precommit"
    assert prompt =~ "invoke the `codex-review` skill 2 time(s)"
    assert prompt =~ "PtcManager does not run or verify these reviews"
    assert prompt =~ "Do not use GitHub credentials"
    assert prompt =~ "credential-isolated broker"
  end

  test "can assign fenced branch push and PR creation to the coding agent" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)

    repository = repository_fixture(%{required_pre_pr_reviews: 2})
    remote = remote_issue(1627) |> Map.put("title", "Correct MCP documentation")
    issue = issue_fixture(repository, IssueSnapshot.normalize!(remote, repository.id))
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    assert is_nil(job.publication_source)

    canonical = IssueSnapshot.normalize!(remote, repository.id)
    assert {:ok, job} = Operations.lease_job(job.id, "herdr:default", canonical, 60_000)
    assert job.publication_source == "agent"

    job =
      job
      |> Job.changeset(%{branch_name: "ptc-manager/issue-1627-job-#{job.id}"})
      |> Repo.update!()

    prompt = PtcManager.Dispatch.HerdrAdapter.build_prompt(repository, issue, job)

    assert prompt =~ "push the existing job branch and create one pull request"
    assert prompt =~ "Use GitHub credentials only to push `#{job.branch_name}`"
    assert prompt =~ "include `Closes #1627`"
    assert prompt =~ "do not merge anything"
    assert prompt =~ "pull-request URL"
    refute prompt =~ "Do not use GitHub credentials"
  end

  defp approved_job_fixture do
    repository = repository_fixture(%{local_path: "/tmp/repository"})
    remote = remote_issue(System.unique_integer([:positive]))
    attrs = IssueSnapshot.normalize!(remote, repository.id)
    issue = issue_fixture(repository, attrs)
    proposal = proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")
    {repository, issue, proposal, job, remote}
  end

  defp remote_issue(number) do
    %{
      "number" => number,
      "title" => "Implement fenced dispatch",
      "html_url" => "https://github.com/example/repo/issues/#{number}",
      "body" => "Create one safe implementation attempt.",
      "state" => "open",
      "updated_at" => "2026-08-29T09:00:00Z"
    }
  end
end
