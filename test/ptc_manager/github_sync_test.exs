defmodule PtcManager.GitHubSyncTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.GitHub.Sync
  alias PtcManager.Operations.{Issue, Repository}
  alias PtcManager.Repo

  defmodule FakeClient do
    @behaviour PtcManager.GitHub
    def list_open_issues(_repository), do: Process.get(:github_result)
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

  test "updates changed content and closes issues missing from a complete snapshot" do
    repository = repository_fixture()
    Process.put(:github_result, {:ok, [remote_issue(44, "First"), remote_issue(45, "Gone")]})
    assert {:ok, _summary} = Sync.sync_repository(repository, client: FakeClient)

    issue = Repo.get_by!(Issue, repository_id: repository.id, number: 44)
    proposal_fixture(issue)

    changed = remote_issue(44, "Changed", "2026-08-29T08:30:00Z")
    Process.put(:github_result, {:ok, [changed]})

    assert {:ok, %{changed_count: 1, closed_count: 1}} =
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

    assert_receive {:github_fetch_started, second_fetch}

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
