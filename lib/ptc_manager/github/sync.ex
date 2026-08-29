defmodule PtcManager.GitHub.Sync do
  @moduledoc "Persists complete read-only GitHub issue snapshots transactionally."

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.Operations.{Issue, Repository}
  alias PtcManager.Repo

  def sync_enabled_repositories do
    Operations.list_repositories()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(&sync_repository/1)
  end

  def sync_repository(%Repository{} = repository, opts \\ []) do
    client = Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :github_client))

    :global.trans({{__MODULE__, repository.id}, self()}, fn ->
      do_sync_repository(repository, client)
    end)
  end

  defp do_sync_repository(repository, client) do
    syncing_repository = mark_syncing(repository)

    case client.list_open_issues(syncing_repository) do
      {:ok, remote_issues} -> persist_snapshot(syncing_repository, remote_issues)
      {:error, reason} -> mark_failed(syncing_repository, reason)
    end
  end

  defp persist_snapshot(repository, remote_issues) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        normalized = Enum.map(remote_issues, &IssueSnapshot.normalize!(&1, repository.id))
        open_numbers = MapSet.new(normalized, & &1.number)

        existing_issues =
          Issue
          |> where([issue], issue.repository_id == ^repository.id)
          |> Repo.all()

        issues_by_number = Map.new(existing_issues, &{&1.number, &1})

        changed_count =
          Enum.count(normalized, fn attrs ->
            upsert_issue(Map.get(issues_by_number, attrs.number), attrs) == :changed
          end)

        closed_count = close_missing_issues(existing_issues, open_numbers)

        synced_repository =
          repository
          |> Repository.changeset(%{
            local_path:
              Application.get_env(:ptc_manager, :repository_path) || repository.local_path,
            sync_status: "ok",
            last_synced_at: now,
            last_sync_error: nil
          })
          |> Repo.update!()

        %{
          repository: synced_repository,
          issue_count: length(normalized),
          changed_count: changed_count,
          closed_count: closed_count
        }
      end)

    case result do
      {:ok, summary} ->
        Operations.notify_changed(__MODULE__)
        {:ok, summary}

      {:error, reason} ->
        mark_failed(repository, reason)
    end
  rescue
    error -> mark_failed(repository, error)
  end

  defp upsert_issue(nil, attrs) do
    %Issue{} |> Issue.changeset(attrs) |> Repo.insert!()
    :changed
  end

  defp upsert_issue(%Issue{content_digest: digest}, %{content_digest: digest}), do: :unchanged

  defp upsert_issue(%Issue{} = issue, attrs) do
    issue |> Issue.changeset(attrs) |> Repo.update!()
    :changed
  end

  defp close_missing_issues(existing_issues, open_numbers) do
    missing_issues =
      Enum.reject(existing_issues, fn issue ->
        issue.state != "open" or MapSet.member?(open_numbers, issue.number)
      end)

    Enum.each(missing_issues, fn issue ->
      canonical = %{
        "body" => issue.body,
        "number" => issue.number,
        "state" => "closed",
        "title" => issue.title,
        "updated_at" => DateTime.to_iso8601(issue.github_updated_at)
      }

      issue
      |> Issue.changeset(%{
        state: "closed",
        content_digest: canonical |> Jason.encode!() |> IssueSnapshot.digest()
      })
      |> Repo.update!()
    end)

    length(missing_issues)
  end

  defp mark_syncing(repository) do
    syncing_repository =
      repository
      |> Repository.changeset(%{sync_status: "syncing", last_sync_error: nil})
      |> Repo.update!()

    Operations.notify_changed(__MODULE__)
    syncing_repository
  end

  defp mark_failed(repository, reason) do
    message = reason |> inspect(limit: 20, printable_limit: 500) |> String.slice(0, 500)

    repository
    |> Repo.reload!()
    |> Repository.changeset(%{sync_status: "error", last_sync_error: message})
    |> Repo.update()

    Operations.notify_changed(__MODULE__)
    {:error, reason}
  end
end
