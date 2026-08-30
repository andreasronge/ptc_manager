defmodule PtcManager.ExternalPullRequestsTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.MaintainerActions.ExternalPrRepairAdapter
  alias PtcManager.MaintainerActions
  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentAction, PrPublication}
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

  defmodule ConfirmedRepairSync do
    def sync_action(_action, _result),
      do: {:ok, %{pull_request: Process.get(:confirmed_repair_status)}}
  end

  test "imports, updates, and retires GitHub pull requests without fake jobs" do
    repository = repository_fixture()
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

    assert prompt =~ "sandboxed disposable checkout"
    assert prompt =~ "Related issue: none recorded"
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

  test "external repair uses a disposable source mirror and removes its checkout" do
    root =
      Path.join(System.tmp_dir!(), "ptc-external-repair-#{System.unique_integer([:positive])}")

    origin = Path.join(root, "origin.git")
    checkout = Path.join(root, "checkout")
    worktrees = Path.join(root, "worktrees")
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf(root) end)

    git!(root, ["init", "--bare", origin])
    git!(root, ["clone", origin, checkout])
    git!(checkout, ["config", "user.email", "test@example.com"])
    git!(checkout, ["config", "user.name", "Test"])
    File.write!(Path.join(checkout, "README.md"), "repair fixture\n")
    git!(checkout, ["add", "README.md"])
    git!(checkout, ["commit", "-m", "initial"])
    git!(checkout, ["push", "origin", "HEAD:main"])
    head_sha = git!(checkout, ["rev-parse", "HEAD"])
    git!(origin, ["update-ref", "refs/pull/94/head", head_sha])
    git!(origin, ["update-ref", "refs/heads/external/fix-94", head_sha])

    source_git_dir = Path.join(checkout, ".git")
    chmod!(source_git_dir, "a-w")
    on_exit(fn -> chmod!(source_git_dir, "u+w") end)

    repository = repository_fixture(%{local_path: checkout})

    status = %{external_status(repository, 94, head_sha) | base_sha: head_sha}
    {:ok, _summary} = Publications.sync_external_open_pull_requests(repository, [status])

    publication = Repo.get_by!(PrPublication, repository_id: repository.id, pr_number: 94)
    {:ok, action} = MaintainerActions.enqueue("repair_pr", publication.id, "maintainer")

    {:ok, _prepared} =
      Operations.record_agent_action_target_snapshot(action.id, %{"head_sha" => head_sha})

    {:ok, {action, _token}} = Operations.claim_agent_action(action.id)

    previous_adapter = Application.get_env(:ptc_manager, :external_pr_codex_adapter)
    previous_root = Application.get_env(:ptc_manager, :external_pr_worktree_root)
    previous_user = Application.get_env(:ptc_manager, :agent_action_run_as_user)
    previous_broker = Application.get_env(:ptc_manager, :external_pr_push_broker)
    previous_source_remote = Application.get_env(:ptc_manager, :external_pr_source_remote)

    Application.put_env(:ptc_manager, :external_pr_codex_adapter, FakeRepairCodex)
    Application.put_env(:ptc_manager, :external_pr_push_broker, FakeRepairPush)
    Application.put_env(:ptc_manager, :external_pr_worktree_root, worktrees)
    Application.put_env(:ptc_manager, :agent_action_run_as_user, nil)
    Application.put_env(:ptc_manager, :external_pr_source_remote, origin)
    Process.put(:external_repair_test_pid, self())
    Process.put(:external_repair_origin, origin)

    on_exit(fn ->
      restore_env(:external_pr_codex_adapter, previous_adapter)
      restore_env(:external_pr_worktree_root, previous_root)
      restore_env(:agent_action_run_as_user, previous_user)
      restore_env(:external_pr_push_broker, previous_broker)
      restore_env(:external_pr_source_remote, previous_source_remote)
    end)

    assert {:ok, %{"outcome" => "repaired"}} = ExternalPrRepairAdapter.run(action)
    assert_receive {:external_repair_path, action_id, path}
    assert_receive {:external_repair_opts, [sandboxed: true, run_as_user: nil]}
    assert action_id == action.id
    refute File.exists?(path)
    refute git!(checkout, ["worktree", "list", "--porcelain"]) =~ "external-pr-#{publication.id}"
    assert git!(origin, ["rev-parse", "refs/heads/external/fix-94"]) != head_sha
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

  defp git!(directory, args) do
    case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp chmod!(path, mode) do
    case System.cmd("chmod", ["-R", mode, path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("chmod failed (#{status}): #{output}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
