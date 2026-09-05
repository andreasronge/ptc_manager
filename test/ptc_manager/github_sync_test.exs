defmodule PtcManager.GitHubSyncTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.GitHub.{IssueSnapshot, Sync}
  alias PtcManager.Operations.{Issue, IssueDependency, Repository}
  alias PtcManager.Repo

  defmodule FakeClient do
    @behaviour PtcManager.GitHub

    @impl true
    def list_open_issues(_repository), do: Process.get(:github_result)

    @impl true
    def viewer_login, do: Process.get(:github_viewer_login, {:error, :not_configured})

    @impl true
    def get_issue(_repository, number) do
      case Process.get(:github_issue_results) do
        results when is_map(results) -> Map.fetch!(results, number)
        _results -> Process.get(:github_issue_result)
      end
    end
  end

  defmodule CoordinatedClient do
    @behaviour PtcManager.GitHub

    def list_open_issues(_repository) do
      test = Application.fetch_env!(:ptc_manager, :github_sync_test_pid)
      send(test, {:github_fetch_started, self()})

      receive do
        {:release_github_fetch, result} -> result
      end
    end

    def get_issue(_repository, _number), do: {:error, :not_supported}
  end

  test "synchronizes an open issue and records repository health" do
    repository = repository_fixture()
    Process.put(:github_result, {:ok, [remote_issue(44, "A real issue")]})

    assert {:ok, %{issue_count: 1, changed_count: 1, closed_count: 0}} =
             Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 44)
    assert issue.title == "A real issue"
    assert issue.body == "Issue body 44"

    synced_repository = Repo.get!(Repository, repository.id)
    assert synced_repository.sync_status == "ok"
    assert synced_repository.last_synced_at

    assert {:ok, %{changed_count: 0}} =
             Sync.sync_repository(synced_repository, client: FakeClient)

    assert Repo.get!(Repository, repository.id).sync_status == "ok"
  end

  test "records when GitHub says the issue was opened without changing the digest" do
    repository = repository_fixture()

    remote =
      45
      |> remote_issue("Aged issue")
      |> Map.put("created_at", "2026-07-01T09:15:00Z")

    Process.put(:github_result, {:ok, [remote]})
    assert {:ok, %{changed_count: 1}} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 45)
    assert issue.github_created_at == ~U[2026-07-01 09:15:00.000000Z]

    # The creation time must stay outside the content digest, or every issue
    # would look changed on the first sync after this release.
    without_created_at = IssueSnapshot.normalize!(remote_issue(45, "Aged issue"), repository)
    assert issue.content_digest == without_created_at.content_digest
  end

  test "records who PtcManager reads GitHub as, and who opened each issue" do
    repository = repository_fixture()
    Process.put(:github_viewer_login, {:ok, "andreasronge"})

    remote =
      50
      |> remote_issue("Reported from outside")
      |> Map.put("author_login", "a-stranger")

    Process.put(:github_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    assert Repo.get!(Repository, repository.id).github_viewer_login == "andreasronge"

    assert Repo.get_by!(Issue, repository_id: repository.id, number: 50).github_author_login ==
             "a-stranger"

    # An identity lookup that fails must not erase the last known one.
    Process.put(:github_viewer_login, {:error, :github_graphql_token_required})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)
    assert Repo.get!(Repository, repository.id).github_viewer_login == "andreasronge"
  end

  test "keeps every GitHub label name outside the content digest" do
    repository = repository_fixture()

    remote =
      55
      |> remote_issue("Labelled issue")
      |> Map.put("labels", [%{"name" => "wait"}, %{"name" => "bug"}, %{"name" => "ptc:ready"}])

    Process.put(:github_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 55)
    assert issue.github_labels == %{"names" => ["bug", "ptc:ready", "wait"]}
    assert issue.workflow_label == "ptc:ready"

    only_managed =
      remote_issue(55, "Labelled issue")
      |> Map.put("labels", [%{"name" => "ptc:ready"}])
      |> IssueSnapshot.normalize!(repository)

    assert issue.content_digest == only_managed.content_digest
  end

  test "backfills projection fields onto an issue whose canonical content is unchanged" do
    repository = repository_fixture()
    remote = remote_issue(60, "Already synchronized")

    Process.put(:github_result, {:ok, [remote]})
    Process.put(:github_viewer_login, {:ok, "andreasronge"})
    assert {:ok, %{changed_count: 1}} = Sync.sync_repository(repository, client: FakeClient)

    # Simulate a row written before this release: identical canonical content,
    # but none of the new out-of-digest projection fields.
    Repo.get_by!(Issue, repository_id: repository.id, number: 60)
    |> Ecto.Changeset.change(%{
      github_created_at: nil,
      github_author_login: nil,
      github_labels: %{"names" => []}
    })
    |> Repo.update!()

    enriched =
      remote
      |> Map.put("created_at", "2026-07-04T10:00:00Z")
      |> Map.put("author_login", "a-stranger")
      |> Map.put("labels", [%{"name" => "wait"}])

    Process.put(:github_result, {:ok, [enriched]})

    # Nothing canonical changed, so this is not a content change...
    assert {:ok, %{changed_count: 0}} = Sync.sync_repository(repository, client: FakeClient)

    # ...but the projection GitHub reports must still land locally.
    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 60)
    assert issue.github_created_at == ~U[2026-07-04 10:00:00.000000Z]
    assert issue.github_author_login == "a-stranger"
    assert issue.github_labels == %{"names" => ["wait"]}
  end

  test "recognizes a workflow label whatever casing GitHub reports" do
    repository = repository_fixture()

    blocked =
      65
      |> remote_issue("Blocked in shouty case")
      |> Map.put("labels", [%{"name" => "PTC:Blocked"}])

    Process.put(:github_result, {:ok, [blocked]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 65)

    assert issue.workflow_label == "ptc:blocked"
    refute issue.workflow_label_conflict

    # A blocked issue must not be startable, and Fix directly reads the same
    # projection the approve gate does.
    assert {:error, :issue_workflow_not_ready} =
             PtcManager.Operations.approve_issue_directly(issue.id, "andreas")

    conflicting =
      66
      |> remote_issue("Two workflow labels")
      |> Map.put("labels", [%{"name" => "PTC:ready"}, %{"name" => "ptc:blocked"}])

    Process.put(:github_result, {:ok, [blocked, conflicting]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    conflicted = Repo.get_by!(Issue, repository_id: repository.id, number: 66)
    assert conflicted.workflow_label_conflict
    assert is_nil(conflicted.workflow_label)

    # The same label twice in different casing is one label, not a conflict.
    duplicated =
      67
      |> remote_issue("One label written twice")
      |> Map.put("labels", [%{"name" => "PTC:ready"}, %{"name" => "ptc:ready"}])

    Process.put(:github_result, {:ok, [blocked, conflicting, duplicated]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    single = Repo.get_by!(Issue, repository_id: repository.id, number: 67)
    assert single.workflow_label == "ptc:ready"
    refute single.workflow_label_conflict
  end

  test "synchronizes the canonical managed workflow label" do
    repository = repository_fixture()

    remote =
      remote_issue(46, "Prepared issue")
      |> Map.put("labels", [%{"name" => "documentation"}, %{"name" => "ptc:ready"}])

    Process.put(:github_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 46)
    assert issue.workflow_label == "ptc:ready"
  end

  test "projects GitHub assignees as the advisory issue claim" do
    repository = repository_fixture()

    assigned =
      remote_issue(48, "Already being implemented")
      |> Map.put("assignees", [
        %{"login" => "worker-two"},
        %{"login" => "worker-one"},
        %{"login" => "worker-one"}
      ])

    Process.put(:github_result, {:ok, [assigned]})
    assert {:ok, %{changed_count: 1}} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 48)
    assert issue.github_assignees == %{"logins" => ["worker-one", "worker-two"]}

    Process.put(:github_result, {:ok, [Map.put(assigned, "assignees", [])]})
    assert {:ok, %{changed_count: 1}} = Sync.sync_repository(repository, client: FakeClient)
    assert Repo.get!(Issue, issue.id).github_assignees == %{"logins" => []}
  end

  test "an empty assignment preserves the pre-projection canonical digest" do
    repository = repository_fixture()
    remote = remote_issue(49, "Still unclaimed")

    legacy_canonical = %{
      "body" => remote["body"],
      "number" => remote["number"],
      "state" => remote["state"],
      "title" => remote["title"],
      "workflow_labels" => [],
      "updated_at" => remote["updated_at"]
    }

    legacy_digest = legacy_canonical |> Jason.encode!() |> IssueSnapshot.digest()

    attrs =
      remote
      |> IssueSnapshot.normalize!(repository.id)
      |> Map.put(:content_digest, legacy_digest)
      |> Map.put(:github_assignment_projected, false)

    {:ok, existing} = PtcManager.Operations.create_issue(attrs)
    proposal_fixture(existing)

    Process.put(:github_result, {:ok, [Map.put(remote, "assignees", [])]})
    assert {:ok, %{changed_count: 1}} = Sync.sync_repository(repository, client: FakeClient)

    synchronized = Repo.get!(Issue, existing.id)
    assert synchronized.github_assignment_projected

    [%{proposal: proposal}] = PtcManager.Operations.dashboard_issues()
    assert proposal.source_digest == synchronized.content_digest
  end

  test "projects native same-repository blockers and follows their state" do
    repository = repository_fixture(%{github_owner: "Example", github_name: "Project"})
    blocker = remote_issue(41, "Build the shared primitive")

    dependent =
      remote_issue(42, "Use the shared primitive")
      |> Map.put("blocked_by", [native_blocker("Example/Project", blocker)])

    Process.put(:github_result, {:ok, [blocker, dependent]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    blocker_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 41)
    dependent_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 42)
    dependency = Repo.get_by!(IssueDependency, issue_id: dependent_issue.id)

    assert dependency.blocking_repository_full_name == "example/project"
    assert dependency.blocking_issue_number == 41
    assert dependency.blocking_issue_id == blocker_issue.id
    assert dependency.blocking_state == "open"

    closed = blocker |> Map.put("state", "closed") |> Map.put("state_reason", "completed")
    dependent = Map.put(dependent, "blocked_by", [native_blocker("Example/Project", closed)])
    Process.put(:github_result, {:ok, [dependent]})
    Process.put(:github_issue_results, %{41 => {:ok, closed}})

    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)
    assert Repo.get!(Issue, blocker_issue.id).state == "closed"
    assert Repo.get!(IssueDependency, dependency.id).blocking_state_reason == "completed"
  end

  test "keeps an accessible cross-repository blocker as an exact snapshot" do
    repository = repository_fixture(%{github_owner: "Example", github_name: "Project"})

    blocker =
      remote_issue(51, "Shared platform prerequisite")
      |> Map.put("state", "closed")
      |> Map.put("state_reason", "not_planned")

    dependent =
      remote_issue(52, "Use the platform")
      |> Map.put("blocked_by", [native_blocker("Other/Platform", blocker)])

    Process.put(:github_result, {:ok, [dependent]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 52)
    dependency = Repo.get_by!(IssueDependency, issue_id: issue.id)

    assert dependency.blocking_repository_full_name == "other/platform"
    assert dependency.blocking_issue_number == 51
    assert dependency.blocking_title == "Shared platform prerequisite"
    assert dependency.blocking_state == "closed"
    assert dependency.blocking_state_reason == "not_planned"
    assert is_nil(dependency.blocking_repository_id)
    assert is_nil(dependency.blocking_issue_id)

    proposal_fixture(issue)

    assert {:error, :issue_dependencies_unresolved} =
             PtcManager.Operations.approve_issue(issue.id, "andreas")
  end

  test "targeted synchronization removes a native dependency removed on GitHub" do
    repository = repository_fixture(%{github_owner: "example", github_name: "project"})

    with_blocker =
      remote_issue(62, "Targeted dependent")
      |> Map.put("blocked_by", [
        native_blocker("example/project", remote_issue(61, "Prerequisite"))
      ])

    Process.put(:github_issue_results, %{62 => {:ok, with_blocker}})
    assert {:ok, _summary} = Sync.sync_issue(repository, 62, client: FakeClient)
    assert Repo.aggregate(IssueDependency, :count) == 1

    Process.put(:github_issue_results, %{62 => {:ok, Map.put(with_blocker, "blocked_by", [])}})
    assert {:ok, _summary} = Sync.sync_issue(repository, 62, client: FakeClient)
    assert Repo.aggregate(IssueDependency, :count) == 0
  end

  test "a native blocker with unknown state fails closed" do
    repository = repository_fixture(%{github_owner: "example", github_name: "project"})

    blocker = native_blocker("private/hidden", remote_issue(80, "Hidden prerequisite"))

    dependent =
      remote_issue(82, "Dependent") |> Map.put("blocked_by", [Map.delete(blocker, "state")])

    Process.put(:github_result, {:ok, [dependent]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 82)
    dependency = Repo.get_by!(IssueDependency, issue_id: issue.id)
    assert dependency.lookup_state == "pending"
    proposal_fixture(issue)

    assert {:error, :issue_dependencies_unresolved} =
             PtcManager.Operations.approve_issue(issue.id, "andreas")
  end

  test "native dependency overflow stays bounded and fails approval closed" do
    repository = repository_fixture(%{github_owner: "example", github_name: "project"})

    blockers =
      Enum.map(1..101, fn number ->
        blocker =
          remote_issue(number, "Closed blocker #{number}")
          |> Map.put("state", "closed")
          |> Map.put("state_reason", "completed")

        native_blocker("example/project", blocker)
      end)

    dependent = remote_issue(600, "Too many dependencies") |> Map.put("blocked_by", blockers)
    Process.put(:github_issue_results, %{600 => {:ok, dependent}})

    assert {:ok, _summary} = Sync.sync_issue(repository, 600, client: FakeClient)
    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 600)
    assert issue.dependency_overflow
    assert Repo.aggregate(IssueDependency, :count) == 100
  end

  test "dependency prose is not treated as a native relationship" do
    repository = repository_fixture()

    dependent =
      remote_issue(610, "Prose is not authority")
      |> Map.put("body", "Blocked by #609")

    Process.put(:github_result, {:ok, [dependent]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)
    assert Repo.aggregate(IssueDependency, :count) == 0
  end

  test "normalizes and deduplicates native blocker repository identities" do
    blocker = remote_issue(12, "Prerequisite")

    remote =
      remote_issue(42, "Dependent")
      |> Map.put("blocked_by", [
        native_blocker("Owner/Repo", blocker),
        native_blocker("owner/repo", blocker)
      ])

    assert [%{repository_full_name: "owner/repo", number: 12}] =
             IssueSnapshot.blocking_issues(remote, "fallback/repo")
  end

  test "surfaces conflicting managed workflow labels instead of choosing one" do
    repository = repository_fixture()

    remote =
      remote_issue(48, "Conflicting labels")
      |> Map.put("labels", [
        %{"name" => "ptc:ready"},
        %{"name" => "ptc:blocked"}
      ])

    Process.put(:github_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 48)
    refute issue.workflow_label
    assert issue.workflow_label_conflict
  end

  test "targeted synchronization preserves an edited issue after it is closed" do
    repository = repository_fixture()
    Process.put(:github_result, {:ok, [remote_issue(49, "Old title")]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    repository =
      repository
      |> Repository.changeset(%{sync_status: "error", last_sync_error: "full snapshot failed"})
      |> Repo.update!()

    closed = %{
      "number" => 49,
      "title" => "Canonical closed title",
      "html_url" => "https://github.com/example/repo/issues/49",
      "body" => "The final close explanation.",
      "state" => "closed",
      "labels" => [],
      "updated_at" => "2026-08-29T09:00:00Z"
    }

    Process.put(:github_issue_result, {:ok, closed})
    assert {:ok, %{issue_number: 49}} = Sync.sync_issue(repository, 49, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 49)
    assert issue.state == "closed"
    assert issue.title == "Canonical closed title"
    assert issue.body == "The final close explanation."

    unchanged_health = Repo.get!(Repository, repository.id)
    assert unchanged_health.sync_status == "error"
    assert unchanged_health.last_sync_error == "full snapshot failed"
  end

  test "updates changed content and closes issues missing from a complete snapshot" do
    repository = repository_fixture()
    Process.put(:github_result, {:ok, [remote_issue(44, "First"), remote_issue(45, "Gone")]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 44)
    proposal_fixture(issue)

    changed = remote_issue(44, "Changed", "2026-08-29T08:30:00Z")
    Process.put(:github_result, {:ok, [changed]})

    Process.put(:github_issue_results, %{
      45 =>
        {:ok,
         remote_issue(45, "Gone", "2026-08-29T08:31:00Z")
         |> Map.put("state", "closed")}
    })

    assert {:ok, %{changed_count: 2, closed_count: 1}} =
             Sync.sync_repository(repository, client: FakeClient)

    changed_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 44)
    closed_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 45)

    assert changed_issue.title == "Changed"
    assert closed_issue.state == "closed"

    [%{proposal: proposal}] =
      PtcManager.Operations.dashboard_issues()
      |> Enum.filter(&(&1.issue.id == changed_issue.id))

    refute proposal.source_digest == changed_issue.content_digest
  end

  test "clears the projected workflow label when an issue disappears as closed" do
    repository = repository_fixture()

    remote =
      remote_issue(47, "Will close")
      |> Map.put("labels", [%{"name" => "ptc:blocked"}])

    Process.put(:github_result, {:ok, [remote]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    Process.put(:github_result, {:ok, []})

    Process.put(:github_issue_results, %{
      47 =>
        {:ok,
         remote_issue(47, "Will close", "2026-08-29T08:31:00Z")
         |> Map.put("state", "closed")
         |> Map.put("labels", [%{"name" => "ptc:blocked"}])}
    })

    assert {:ok, %{closed_count: 1}} = Sync.sync_repository(repository, client: FakeClient)

    closed = Repo.get_by!(Issue, repository_id: repository.id, number: 47)
    assert closed.state == "closed"
    assert closed.workflow_label == "ptc:blocked"
  end

  test "records a bounded failure without changing issue state" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    Process.put(:github_result, {:error, :offline})

    assert {:error, :offline} = Sync.sync_repository(repository, client: FakeClient)
    assert Repo.get!(Issue, issue.id).state == "open"

    failed_repository = Repo.get!(Repository, repository.id)
    assert failed_repository.sync_status == "error"
    assert failed_repository.last_sync_error =~ "offline"
  end

  test "serializes overlapping snapshots for the same repository" do
    repository = repository_fixture()
    Application.put_env(:ptc_manager, :github_sync_test_pid, self())
    on_exit(fn -> Application.delete_env(:ptc_manager, :github_sync_test_pid) end)

    first = Task.async(fn -> Sync.sync_repository(repository, client: CoordinatedClient) end)
    assert_receive {:github_fetch_started, first_fetch}

    second = Task.async(fn -> Sync.sync_repository(repository, client: CoordinatedClient) end)
    refute_receive {:github_fetch_started, _second_fetch}, 100

    send(first_fetch, {:release_github_fetch, {:ok, [remote_issue(44, "Older")]}})
    assert {:ok, _summary} = Task.await(first)

    # :global.trans retries contended locks with randomized backoff; releasing
    # the first sync does not immediately wake the second one.
    assert_receive {:github_fetch_started, second_fetch}, 5_000

    send(second_fetch, {
      :release_github_fetch,
      {:ok, [remote_issue(44, "Newer", "2026-08-29T08:30:00Z")]}
    })

    assert {:ok, _summary} = Task.await(second)
    assert Repo.get_by!(Issue, repository_id: repository.id, number: 44).title == "Newer"
    assert Repo.get!(Repository, repository.id).sync_status == "ok"
  end

  defp native_blocker(full_name, blocker) do
    blocker
    |> Map.put("id", blocker["number"] + 10_000)
    |> Map.put("node_id", "ISSUE_#{blocker["number"]}")
    |> Map.put("repository", %{"full_name" => full_name})
    |> Map.put("repository_url", "https://api.github.com/repos/#{full_name}")
    |> Map.put("html_url", "https://github.com/#{full_name}/issues/#{blocker["number"]}")
  end

  defp remote_issue(number, title, updated_at \\ "2026-08-29T08:00:00Z") do
    %{
      "number" => number,
      "title" => title,
      "html_url" => "https://github.com/example/repo/issues/#{number}",
      "body" => "Issue body #{number}",
      "state" => "open",
      "updated_at" => updated_at
    }
  end
end
