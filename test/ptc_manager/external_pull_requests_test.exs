defmodule PtcManager.ExternalPullRequestsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.ExternalPrRepairAdapter
  alias PtcManager.MaintainerActions
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, Job, PrPublication}
  alias PtcManager.Publications
  alias PtcManager.Repo

  defmodule ListingClient do
    def list_open(_repository), do: {:ok, Process.get(:external_pull_listing, [])}

    def status(publication) do
      case Enum.find(
             Process.get(
               :external_pull_statuses,
               Process.get(:external_pull_listing, [])
             ),
             &(&1.pr_number == publication.pr_number)
           ) do
        nil -> {:blocked, :not_found}
        pull -> {:ok, pull}
      end
    end
  end

  defmodule FakeRepairCodex do
    def run_at(action, path, opts) do
      send(Process.get(:external_repair_test_pid), {:external_repair_path, action.id, path})
      send(Process.get(:external_repair_test_pid), {:external_repair_opts, opts})
      File.write!(Path.join(path, "repair.txt"), "sandboxed repair\n")

      {:ok,
       %{
         "outcome" => "repaired",
         "private_summary" => "Repair completed in the disposable checkout."
       }}
    end
  end

  defmodule FakeRepairPush do
    def push_external_repair(
          path,
          _repository,
          publication,
          expected_sha,
          repaired_sha,
          _required_base
        ) do
      origin = Process.get(:external_repair_origin)

      case System.cmd(
             "git",
             [
               "-C",
               path,
               "push",
               "--force-with-lease=refs/heads/#{publication.head_ref}:#{expected_sha}",
               origin,
               "#{repaired_sha}:refs/heads/#{publication.head_ref}"
             ],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:test_push_failed, status, output}}
      end
    end
  end

  defmodule FakeRepairHerdr do
    def start_pull_request_action(action, publication, _repository) do
      send(Process.get(:external_repair_test_pid), {:herdr_started, action.id, publication.id})

      {:ok,
       %{
         workspace_id: "repair-workspace",
         pane_id: "repair-pane",
         session: "test",
         external_key: "test:repair-agent",
         agent_name: "repair_pr#{publication.pr_number}_a#{action.id}_f#{action.attempt_count}",
         worktree_path: "/tmp/repair-worktree",
         worker_key: "herdr:test"
       }}
    end

    def prompt_pull_request_action(agent_name, prompt) do
      send(Process.get(:external_repair_test_pid), {:herdr_prompted, agent_name, prompt})
      {:ok, Jason.encode!(%{"agent_status" => "idle"})}
    end

    def pull_request_action_head(_path),
      do: {:ok, Process.get(:external_repair_head, String.duplicate("e", 40))}
  end

  defmodule ConfirmedRepairSync do
    def sync_action(_action, _result),
      do: {:ok, %{pull_request: Process.get(:confirmed_repair_status)}}
  end

  defmodule PromptCaptureRepairAdapter do
    def run(action) do
      send(Process.get(:external_repair_test_pid), {:executed_prompt, action.prompt})

      {:ok,
       %{
         "outcome" => "repair-blocked",
         "private_summary" => "Stopped before changing the pull request."
       }}
    end
  end

  defmodule PromptCaptureRepairSync do
    def sync_action(_action), do: {:ok, %{pull_request: Process.get(:capture_repair_status)}}
    def sync_action(action, _result), do: sync_action(action)
  end

  test "imports, updates, and retires GitHub pull requests without fake jobs" do
    repository = repository_fixture(%{local_path: File.cwd!()})
    first = external_status(repository, 91, String.duplicate("b", 40))

    assert {:ok, %{open_count: 1}} =
             Publications.sync_external_open_pull_requests(repository, [first])

    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 91)
    assert publication.source == "external"
    assert publication.job_id == nil
    assert publication.title == "External repair candidate"
    assert publication.remote_head_sha == String.duplicate("b", 40)
    first_digest = publication.diff_digest

    assert {:ok, _publication} = Publications.record_status_error(publication.id, :rate_limited)

    assert {:ok, %{open_count: 1}} =
             Publications.sync_external_open_pull_requests(repository, [first])

    assert Repo.get!(PrPublication, publication.id).last_error =~ "rate_limited"

    updated = %{first | head_sha: String.duplicate("c", 40), checks_state: "success"}

    assert {:ok, %{open_count: 1}} =
             Publications.sync_external_open_pull_requests(repository, [updated])

    publication = Repo.get!(PrPublication, publication.id)
    assert publication.remote_head_sha == String.duplicate("c", 40)
    assert publication.checks_state == "success"
    assert publication.last_error == nil
    refute publication.diff_digest == first_digest

    assert {:ok, %{closed_count: 0}} =
             Publications.sync_external_open_pull_requests(repository, [])

    assert Repo.get!(PrPublication, publication.id).pr_state == "open"

    assert {:ok, %{closed_count: 0}} =
             Publications.sync_external_open_pull_requests(repository, [])

    assert Repo.get!(PrPublication, publication.id).pr_state == "open"

    Process.put(:external_pull_listing, [])
    Process.put(:external_pull_statuses, [%{updated | state: "closed"}])

    assert {:ok, _summary} =
             PtcManager.PublicationStatusReconciler.run_once(
               client: ListingClient,
               external: true
             )

    assert Repo.get!(PrPublication, publication.id).pr_state == "closed"
  end

  test "does not import an agent PR before its managed publication row exists" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    branch = "ptc-manager/issue-#{issue.number}-job-#{job.id}"

    job
    |> Job.changeset(%{
      state: "working",
      branch_name: branch,
      publication_source: "agent",
      fencing_token: 1
    })
    |> Repo.update!()

    pull =
      repository
      |> external_status(99, String.duplicate("b", 40))
      |> Map.put(:head_ref, branch)

    assert {:ok, %{open_count: 0}} =
             Publications.sync_external_open_pull_requests(repository, [pull])

    refute Repo.get_by(PrPublication, repository_id: repository.id, pr_number: 99)
  end

  test "external pull requests have isolated repair but no retained-context actions" do
    repository = repository_fixture()

    {:ok, _summary} =
      Publications.sync_external_open_pull_requests(repository, [
        external_status(repository, 92, String.duplicate("d", 40))
      ])

    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 92)
    keys = Catalog.pull_request_actions(publication) |> Enum.map(& &1.key)

    assert "repair_pr" in keys
    refute "prepare_merge_decision" in keys
    refute "pr_retrospective" in keys

    assert {:error, :pull_request_has_no_retained_session} =
             Catalog.build("pr_retrospective", %{
               repository: repository,
               issue: nil,
               publication: publication
             })

    assert {:ok, %{prompt: prompt}} =
             Catalog.build("repair_pr", %{
               repository: repository,
               issue: nil,
               publication: publication
             })

    assert "repair_and_merge_pr" in keys
    assert prompt =~ "fresh isolated worktree"
    assert prompt =~ "Push its final HEAD explicitly"
    assert prompt =~ "Related issue: none recorded"

    assert {:ok, %{prompt: merge_prompt}} =
             Catalog.build("repair_and_merge_pr", %{
               repository: repository,
               issue: nil,
               publication: publication
             })

    assert merge_prompt =~ "explicit maintainer authorization to merge only pull request #92"
    assert merge_prompt =~ "same Herdr session"
    assert merge_prompt =~ "wait for every required GitHub check"
    assert merge_prompt =~ "Merge with the authenticated `gh` CLI"
    assert merge_prompt =~ "do not finish the run until GitHub confirms the PR is merged"
  end

  test "a previously queued external merge review is rejected before execution" do
    repository = repository_fixture()
    status = external_status(repository, 96, String.duplicate("d", 40))
    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])
    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 96)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    queued =
      %AgentAction{}
      |> AgentAction.changeset(%{
        repository_id: repository.id,
        action_key: "prepare_merge_decision",
        target_type: "pull_request",
        target_id: publication.id,
        target_label: "external PR #96",
        prompt_version: 1,
        prompt: "legacy prompt",
        actor: "maintainer",
        requested_at: now
      })
      |> Repo.insert!()

    assert {:ok, failed} =
             MaintainerActions.run_once(adapter: FakeRepairCodex, sync: ConfirmedRepairSync)

    assert failed.id == queued.id
    assert failed.state == "failed"
    assert failed.last_error =~ "external_pull_request_has_no_isolated_merge_reviewer"
  end

  test "the reconciler imports the complete GitHub PR listing" do
    repository = repository_fixture()

    Process.put(:external_pull_listing, [
      external_status(repository, 93, String.duplicate("e", 40))
    ])

    assert {:ok, %{open_count: 1}} =
             PtcManager.PublicationStatusReconciler.run_once(
               client: ListingClient,
               external: true
             )

    assert Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 93).source ==
             "external"
  end

  test "external repair starts a named retained Herdr session" do
    repository = repository_fixture(%{local_path: File.cwd!()})
    head_sha = String.duplicate("f", 40)
    status = external_status(repository, 94, head_sha)
    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])

    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 94)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "maintainer")

    {:ok, _prepared} =
      Operations.record_agent_action_target_snapshot(action.id, %{"head_sha" => head_sha})

    {:ok, {action, _token}} = Operations.claim_agent_action(action.id)

    previous_adapter = Application.get_env(:ptc_manager, :external_pr_herdr_adapter)
    Application.put_env(:ptc_manager, :external_pr_herdr_adapter, FakeRepairHerdr)
    Process.put(:external_repair_test_pid, self())
    Process.put(:external_repair_head, String.duplicate("e", 40))

    on_exit(fn ->
      restore_env(:external_pr_herdr_adapter, previous_adapter)
    end)

    assert {:ok, %{"outcome" => "repaired"}} = ExternalPrRepairAdapter.run(action)
    assert_receive {:herdr_started, action_id, publication_id}
    assert action_id == action.id
    assert publication_id == publication.id
    assert_receive {:herdr_prompted, agent_name, prompt}
    assert agent_name =~ "repair_pr94"
    assert prompt =~ "pull request #94"

    run = Repo.get_by!(PtcManager.Operations.AgentRun, agent_action_id: action.id)
    assert run.agent_name == agent_name
    assert run.herdr_workspace == "repair-workspace"
    assert run.state == "working"

    persisted = Repo.get!(AgentAction, action.id)
    assert persisted.target_snapshot["repair_intended_head_sha"] == String.duplicate("e", 40)
  end

  test "full action preflight preserves the fix-and-merge Herdr authorization prompt" do
    repository = repository_fixture(%{local_path: File.cwd!()})
    status = external_status(repository, 97, String.duplicate("f", 40))
    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])
    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 97)
    {:ok, action} = MaintainerActions.enqueue("repair_and_merge_pr", publication.id, "maintainer")

    Process.put(:external_repair_test_pid, self())
    Process.put(:capture_repair_status, status)

    assert {:ok, completed} =
             MaintainerActions.run_once(
               adapter: PromptCaptureRepairAdapter,
               sync: PromptCaptureRepairSync
             )

    assert completed.id == action.id
    assert_receive {:executed_prompt, prompt}
    assert prompt =~ "same Herdr session"
    assert prompt =~ "Merge with the authenticated `gh` CLI"
    refute prompt =~ "Do not use network access"
  end

  test "external repair stays queued when the private worktree root is unavailable" do
    repository = repository_fixture(%{local_path: File.cwd!()})
    status = external_status(repository, 98, String.duplicate("f", 40))
    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])
    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 98)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "maintainer")

    previous_check = Application.get_env(:ptc_manager, :worktree_permission_check)
    previous_root = Application.get_env(:ptc_manager, :worktree_root)
    previous_uid = Application.get_env(:ptc_manager, :worktree_owner_uid)

    Application.put_env(:ptc_manager, :worktree_permission_check, true)
    Application.put_env(:ptc_manager, :worktree_root, Path.join(File.cwd!(), "missing-root"))
    Application.put_env(:ptc_manager, :worktree_owner_uid, File.stat!(File.cwd!()).uid)
    Process.put(:external_repair_test_pid, self())
    Process.put(:capture_repair_status, status)

    on_exit(fn ->
      restore_env(:worktree_permission_check, previous_check)
      restore_env(:worktree_root, previous_root)
      restore_env(:worktree_owner_uid, previous_uid)
    end)

    assert {:ok, deferred} =
             MaintainerActions.run_once(
               adapter: PromptCaptureRepairAdapter,
               sync: PromptCaptureRepairSync
             )

    assert deferred.id == action.id
    assert deferred.state == "queued"
    assert deferred.sync_attempt_count == 1
    assert deferred.last_error =~ "worktree_root_unavailable"
    refute_receive {:executed_prompt, _prompt}

    deferred
    |> AgentAction.changeset(%{next_sync_attempt_at: nil})
    |> Repo.update!()

    assert {:ok, deferred_again} =
             MaintainerActions.run_once(
               adapter: PromptCaptureRepairAdapter,
               sync: PromptCaptureRepairSync
             )

    assert deferred_again.state == "queued"
    assert deferred_again.sync_attempt_count == 2
    assert DateTime.after?(deferred_again.next_sync_attempt_at, deferred.next_sync_attempt_at)
    refute_receive {:executed_prompt, _prompt}
  end

  test "a persisted repair intent recovers after the push response is lost" do
    repository = repository_fixture()
    original_head = String.duplicate("b", 40)
    repaired_head = String.duplicate("c", 40)
    status = external_status(repository, 95, original_head)

    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])
    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 95)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "maintainer")

    {:ok, _prepared} =
      Operations.record_agent_action_target_snapshot(action.id, %{"head_sha" => original_head})

    {:ok, {running, token}} = Operations.claim_agent_action(action.id)

    {:ok, _intended} =
      Operations.record_agent_action_repair_intent(running.id, token, repaired_head)

    {:ok, pending} =
      Operations.mark_agent_action_sync_pending(
        running.id,
        token,
        {:error, :push_response_lost},
        :github_temporarily_unavailable
      )

    assert pending.state == "sync_pending"

    pending
    |> AgentAction.changeset(%{next_sync_attempt_at: nil})
    |> Repo.update!()

    Process.put(:confirmed_repair_status, %{status | head_sha: repaired_head})

    assert {:ok, completed} =
             MaintainerActions.run_once(adapter: FakeRepairCodex, sync: ConfirmedRepairSync)

    assert completed.state == "done"
    assert completed.result_summary =~ "recovered_after_uncertain_push"
    assert completed.result_summary =~ repaired_head
  end

  defp external_status(repository, number, head_sha) do
    %{
      pr_number: number,
      pr_url:
        "https://github.com/#{repository.github_owner}/#{repository.github_name}/pull/#{number}",
      state: "open",
      draft: false,
      title: "External repair candidate",
      author_login: "outside-author",
      body: "",
      head_sha: head_sha,
      head_ref: "external/fix-#{number}",
      head_repository: "#{repository.github_owner}/#{repository.github_name}",
      base_sha: String.duplicate("a", 40),
      base_ref: repository.default_branch,
      base_repository: "#{repository.github_owner}/#{repository.github_name}",
      mergeability: "conflicting",
      mergeable_state: "dirty",
      checks_state: "failure",
      checks_total: 1,
      checks_failed: 1,
      checks_pending: 0
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
