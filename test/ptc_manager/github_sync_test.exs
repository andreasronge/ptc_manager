defmodule PtcManager.GitHubSyncTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.GitHub.Sync
  alias PtcManager.Operations.{Issue, IssueDependency, Repository}
  alias PtcManager.Repo

  defmodule FakeClient do
    @behaviour PtcManager.GitHub
    def list_open_issues(_repository), do: Process.get(:github_result)

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

  test "projects canonical issue blockers and follows the blocker state" do
    repository = repository_fixture()

    blocker = remote_issue(41, "Build the shared primitive")

    dependent =
      remote_issue(42, "Use the shared primitive")
      |> Map.put("body", "Implementation notes.\n\nBlocked by #41\nBlocked by #41")
      |> Map.put("labels", [%{"name" => "ptc:blocked"}])

    Process.put(:github_result, {:ok, [blocker, dependent]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    blocker_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 41)
    dependent_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 42)
    dependency = Repo.get_by!(IssueDependency, issue_id: dependent_issue.id)

    assert dependency.blocking_issue_number == 41
    assert dependency.blocking_issue_id == blocker_issue.id

    closed_blocker =
      blocker
      |> Map.put("state", "closed")
      |> Map.put("updated_at", "2026-08-29T08:30:00Z")

    Process.put(:github_result, {:ok, [dependent]})
    Process.put(:github_issue_results, %{41 => {:ok, closed_blocker}})

    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)
    assert Repo.get!(Issue, blocker_issue.id).state == "closed"
    assert Repo.aggregate(IssueDependency, :count) == 1
  end

  test "fetches an unknown blocker that was already closed" do
    repository = repository_fixture()

    dependent =
      remote_issue(52, "Use an already completed prerequisite")
      |> Map.put("body", "Blocked by #51")

    closed_blocker =
      remote_issue(51, "Completed prerequisite")
      |> Map.put("state", "closed")

    Process.put(:github_result, {:ok, [dependent]})
    Process.put(:github_issue_results, %{51 => {:ok, closed_blocker}})

    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    blocker_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 51)
    dependent_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 52)
    dependency = Repo.get_by!(IssueDependency, issue_id: dependent_issue.id)

    assert blocker_issue.state == "closed"
    assert dependency.blocking_issue_id == blocker_issue.id
  end

  test "targeted synchronization fetches referenced blocker state" do
    repository = repository_fixture()

    dependent =
      remote_issue(62, "Targeted dependent")
      |> Map.put("body", "Blocked by #61")

    closed_blocker =
      remote_issue(61, "Targeted completed prerequisite")
      |> Map.put("state", "closed")

    Process.put(:github_issue_results, %{
      61 => {:ok, closed_blocker},
      62 => {:ok, dependent}
    })

    assert {:ok, _summary} = Sync.sync_issue(repository, 62, client: FakeClient)

    blocker_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 61)
    dependent_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 62)
    dependency = Repo.get_by!(IssueDependency, issue_id: dependent_issue.id)

    assert blocker_issue.state == "closed"
    assert dependency.blocking_issue_id == blocker_issue.id
  end

  test "targeted synchronization also projects dependencies of a fetched blocker" do
    repository = repository_fixture()

    dependent =
      remote_issue(72, "Targeted dependent")
      |> Map.put("body", "Blocked by #71")

    blocker =
      remote_issue(71, "Blocker with its own prerequisite")
      |> Map.put("body", "Blocked by #70")

    Process.put(:github_issue_results, %{
      71 => {:ok, blocker},
      72 => {:ok, dependent}
    })

    assert {:ok, _summary} = Sync.sync_issue(repository, 72, client: FakeClient)

    blocker_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 71)
    blocker_dependency = Repo.get_by!(IssueDependency, issue_id: blocker_issue.id)

    assert blocker_dependency.blocking_issue_number == 70
    assert is_nil(blocker_dependency.blocking_issue_id)
  end

  test "keeps definitive missing and pull-request references as unknown blockers" do
    repository = repository_fixture()

    dependent =
      remote_issue(82, "Dependent with invalid references")
      |> Map.put("body", "Blocked by #80\nBlocked by #81")

    Process.put(:github_result, {:ok, [dependent]})

    Process.put(:github_issue_results, %{
      80 => {:error, {:github_http_error, 404, "Not Found", nil}},
      81 => {:error, :github_item_is_pull_request}
    })

    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 82)

    dependencies =
      Repo.all(from dependency in IssueDependency, where: dependency.issue_id == ^issue.id)

    assert Enum.map(dependencies, & &1.blocking_issue_number) |> Enum.sort() == [80, 81]
    assert Enum.all?(dependencies, &is_nil(&1.blocking_issue_id))
    assert Enum.map(dependencies, & &1.lookup_state) |> Enum.sort() == ["missing", "pull_request"]
    assert Enum.all?(dependencies, & &1.lookup_checked_at)
  end

  test "later sync batches advance past recently checked unknown references" do
    repository = repository_fixture()
    first_markers = Enum.map_join(1..101, "\n", &"Blocked by ##{&1}")

    first_dependent =
      remote_issue(500, "Many missing blocker references") |> Map.put("body", first_markers)

    later_dependent =
      remote_issue(501, "A later blocker reference") |> Map.put("body", "Blocked by #102")

    final_blocker = remote_issue(102, "The valid later blocker") |> Map.put("state", "closed")

    unknown_results =
      Map.new(1..100, fn number ->
        {number, {:error, {:github_http_error, 404, "Not Found", nil}}}
      end)

    Process.put(:github_result, {:ok, [first_dependent, later_dependent]})
    Process.put(:github_issue_results, Map.put(unknown_results, 102, {:ok, final_blocker}))

    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)
    refute Repo.get_by(Issue, repository_id: repository.id, number: 102)

    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    blocker = Repo.get_by!(Issue, repository_id: repository.id, number: 102)
    dependent_issue = Repo.get_by!(Issue, repository_id: repository.id, number: 501)

    dependency =
      Repo.get_by!(IssueDependency,
        issue_id: dependent_issue.id,
        blocking_issue_number: 102
      )

    assert blocker.state == "closed"
    assert dependency.blocking_issue_id == blocker.id
  end

  test "dependency overflow stays bounded and fails approval closed" do
    repository = repository_fixture()
    markers = Enum.map_join(1..101, "\n", &"Blocked by ##{&1}")
    dependent = remote_issue(600, "Too many dependencies") |> Map.put("body", markers)

    closed_blockers =
      Map.new(1..100, fn number ->
        {number,
         {:ok, remote_issue(number, "Closed blocker #{number}") |> Map.put("state", "closed")}}
      end)

    Process.put(:github_issue_results, Map.put(closed_blockers, 600, {:ok, dependent}))

    assert {:ok, _summary} = Sync.sync_issue(repository, 600, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 600)
    assert issue.dependency_overflow
    assert Repo.aggregate(IssueDependency, :count) == 100

    proposal_fixture(issue)

    assert {:error, :issue_dependencies_unresolved} =
             PtcManager.Operations.approve_issue(issue.id, "andreas")
  end

  test "backfills overflow for an unchanged issue created before the projection existed" do
    repository = repository_fixture()
    markers = Enum.map_join(1..101, "\n", &"Blocked by ##{&1}")
    remote = remote_issue(610, "Existing issue with overflow") |> Map.put("body", markers)

    attrs =
      remote
      |> PtcManager.GitHub.IssueSnapshot.normalize!(repository.id)
      |> Map.put(:dependency_overflow, false)

    {:ok, existing} = PtcManager.Operations.create_issue(attrs)
    refute existing.dependency_overflow

    unknown_results =
      Map.new(1..100, fn number ->
        {number, {:error, {:github_http_error, 404, "Not Found", nil}}}
      end)

    Process.put(:github_issue_results, Map.put(unknown_results, 610, {:ok, remote}))

    assert {:ok, _summary} = Sync.sync_issue(repository, 610, client: FakeClient)
    assert Repo.get!(Issue, existing.id).dependency_overflow
  end

  test "extracts only canonical non-self blockers" do
    assert PtcManager.GitHub.IssueSnapshot.blocking_issue_numbers(
             "Blocked by #12\nblocked BY #9\nBlocked by #12\nBlocked by #42",
             42
           ) == [9, 12]

    assert PtcManager.GitHub.IssueSnapshot.blocking_issue_numbers(
             "Depends on #12 and mentions #9",
             42
           ) == []

    assert PtcManager.GitHub.IssueSnapshot.blocking_issue_numbers(
             "Blocked by #0\nBlocked by #999999999999999999999999",
             42
           ) == []

    many_markers = Enum.map_join(1..25, "\n", &"Blocked by ##{&1}")

    assert many_markers
           |> PtcManager.GitHub.IssueSnapshot.blocking_issue_numbers(42)
           |> length() == 25
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

    assert_receive {:github_fetch_started, second_fetch}, 1_000

    send(second_fetch, {
      :release_github_fetch,
      {:ok, [remote_issue(44, "Newer", "2026-08-29T08:30:00Z")]}
    })

    assert {:ok, _summary} = Task.await(second)
    assert Repo.get_by!(Issue, repository_id: repository.id, number: 44).title == "Newer"
    assert Repo.get!(Repository, repository.id).sync_status == "ok"
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
