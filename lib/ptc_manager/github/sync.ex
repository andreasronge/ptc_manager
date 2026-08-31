defmodule PtcManager.GitHub.Sync do
  @moduledoc "Persists complete read-only GitHub issue snapshots transactionally."

  @max_dependency_lookups_per_sync 100
  @unknown_reference_recheck_seconds 86_400

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.Gateway
  alias PtcManager.GitHub.IssueSnapshot
  alias PtcManager.Operations.{Issue, IssueDependency, Repository}
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

  def sync_issue(%Repository{} = repository, number, opts \\ [])
      when is_integer(number) and number > 0 do
    client = Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :github_client))

    :global.trans({{__MODULE__, repository.id}, self()}, fn ->
      case Gateway.call(client, :get_issue, [repository, number]) do
        {:ok, remote_issue} ->
          with {:ok, referenced_issues, unknown_references} <-
                 fetch_referenced_issues(repository, [remote_issue], client) do
            persist_issue(repository, remote_issue, referenced_issues, unknown_references)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp do_sync_repository(repository, client) do
    syncing_repository = mark_syncing(repository)

    with {:ok, remote_issues} <- Gateway.call(client, :list_open_issues, [syncing_repository]),
         {:ok, missing_issues, unknown_references} <-
           fetch_missing_issues(syncing_repository, remote_issues, client) do
      persist_snapshot(syncing_repository, remote_issues, missing_issues, unknown_references)
    else
      {:error, reason} -> mark_failed(syncing_repository, reason)
    end
  end

  defp persist_snapshot(repository, remote_issues, missing_issues, unknown_references) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        normalized =
          Enum.map(remote_issues ++ missing_issues, &IssueSnapshot.normalize!(&1, repository.id))

        existing_issues =
          Issue
          |> where([issue], issue.repository_id == ^repository.id)
          |> Repo.all()

        issues_by_number = Map.new(existing_issues, &{&1.number, &1})

        changed_count =
          Enum.count(normalized, fn attrs ->
            upsert_issue(Map.get(issues_by_number, attrs.number), attrs) == :changed
          end)

        synchronized_issues =
          Issue
          |> where([issue], issue.repository_id == ^repository.id)
          |> Repo.all()
          |> Map.new(&{&1.number, &1})

        Enum.each(normalized, fn attrs ->
          replace_dependencies(
            Map.fetch!(synchronized_issues, attrs.number),
            attrs.blocking_issue_numbers,
            synchronized_issues
          )
        end)

        record_unknown_references(repository, unknown_references, now)

        closed_count = Enum.count(missing_issues, &(&1["state"] == "closed"))

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
          issue_count: length(remote_issues),
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

  defp persist_issue(repository, remote_issue, referenced_issues, unknown_references) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        attrs = IssueSnapshot.normalize!(remote_issue, repository.id)

        referenced_attrs =
          Enum.map(referenced_issues, &IssueSnapshot.normalize!(&1, repository.id))

        Enum.each(referenced_attrs, fn referenced ->
          upsert_issue(
            Repo.get_by(Issue,
              repository_id: repository.id,
              number: referenced.number
            ),
            referenced
          )
        end)

        existing = Repo.get_by(Issue, repository_id: repository.id, number: attrs.number)
        changed? = upsert_issue(existing, attrs) == :changed

        synchronized_issues =
          Issue
          |> where([issue], issue.repository_id == ^repository.id)
          |> Repo.all()
          |> Map.new(&{&1.number, &1})

        Enum.each([attrs | referenced_attrs], fn synchronized_attrs ->
          replace_dependencies(
            Map.fetch!(synchronized_issues, synchronized_attrs.number),
            synchronized_attrs.blocking_issue_numbers,
            synchronized_issues
          )
        end)

        record_unknown_references(repository, unknown_references, now)

        %{repository: repository, issue_number: attrs.number, changed?: changed?}
      end)

    case result do
      {:ok, summary} ->
        Operations.notify_changed(__MODULE__)
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp upsert_issue(nil, attrs) do
    %Issue{} |> Issue.changeset(attrs) |> Repo.insert!()
    :changed
  end

  defp upsert_issue(
         %Issue{
           content_digest: digest,
           dependency_overflow: overflow,
           dependencies_projected: true,
           github_assignment_projected: true
         },
         %{
           content_digest: digest,
           dependency_overflow: overflow,
           dependencies_projected: true,
           github_assignment_projected: true
         }
       ),
       do: :unchanged

  defp upsert_issue(%Issue{} = issue, attrs) do
    issue |> Issue.changeset(attrs) |> Repo.update!()
    :changed
  end

  defp replace_dependencies(issue, blocking_numbers, issues_by_number) do
    existing =
      IssueDependency
      |> where([dependency], dependency.issue_id == ^issue.id)
      |> Repo.all()
      |> Map.new(&{&1.blocking_issue_number, &1})

    stale_ids =
      existing
      |> Map.drop(blocking_numbers)
      |> Map.values()
      |> Enum.map(& &1.id)

    if stale_ids != [] do
      IssueDependency
      |> where([dependency], dependency.id in ^stale_ids)
      |> Repo.delete_all()
    end

    Enum.each(blocking_numbers, fn blocking_number ->
      blocking_issue = Map.get(issues_by_number, blocking_number)

      attrs = %{
        issue_id: issue.id,
        blocking_issue_id: blocking_issue && blocking_issue.id,
        blocking_issue_number: blocking_number,
        lookup_state: if(blocking_issue, do: "resolved", else: "pending")
      }

      case Map.get(existing, blocking_number) do
        nil ->
          %IssueDependency{} |> IssueDependency.changeset(attrs) |> Repo.insert!()

        dependency ->
          update_attrs =
            if blocking_issue,
              do: Map.put(attrs, :lookup_checked_at, nil),
              else: Map.drop(attrs, [:lookup_state])

          dependency |> IssueDependency.changeset(update_attrs) |> Repo.update!()
      end
    end)
  end

  defp fetch_missing_issues(repository, remote_issues, client) do
    open_numbers = MapSet.new(remote_issues, & &1["number"])

    local_issues =
      Issue
      |> where([issue], issue.repository_id == ^repository.id)
      |> Repo.all()

    known_numbers = MapSet.new(local_issues, & &1.number)
    recently_checked_unknowns = recently_checked_unknown_numbers(repository.id)

    missing_open_numbers =
      local_issues
      |> Enum.filter(&(&1.state == "open" and not MapSet.member?(open_numbers, &1.number)))
      |> Enum.map(& &1.number)

    unknown_referenced_numbers =
      remote_issues
      |> referenced_issue_numbers()
      |> Enum.reject(
        &(MapSet.member?(open_numbers, &1) or MapSet.member?(known_numbers, &1) or
            MapSet.member?(recently_checked_unknowns, &1))
      )

    with {:ok, missing_open_issues, _unknowns} <-
           fetch_issue_numbers(missing_open_numbers, repository, client),
         {:ok, referenced_issues, unknown_references} <-
           unknown_referenced_numbers
           |> Enum.take(@max_dependency_lookups_per_sync)
           |> fetch_issue_numbers(repository, client, allow_unknown: true) do
      {:ok, missing_open_issues ++ referenced_issues, unknown_references}
    end
  end

  defp fetch_referenced_issues(repository, remote_issues, client) do
    remote_numbers = MapSet.new(remote_issues, & &1["number"])
    recently_checked_unknowns = recently_checked_unknown_numbers(repository.id)

    remote_issues
    |> referenced_issue_numbers()
    |> Enum.reject(
      &(MapSet.member?(remote_numbers, &1) or MapSet.member?(recently_checked_unknowns, &1))
    )
    |> Enum.take(@max_dependency_lookups_per_sync)
    |> fetch_issue_numbers(repository, client, allow_unknown: true)
  end

  defp referenced_issue_numbers(remote_issues) do
    remote_issues
    |> Enum.flat_map(fn issue ->
      IssueSnapshot.projected_blocking_issue_numbers(issue["body"] || "", issue["number"])
    end)
    |> Enum.uniq()
  end

  defp fetch_issue_numbers(numbers, repository, client, opts \\ []) do
    allow_unknown? = Keyword.get(opts, :allow_unknown, false)

    Enum.reduce_while(numbers, {:ok, [], %{}}, fn number, {:ok, snapshots, unknowns} ->
      case Gateway.call(client, :get_issue, [repository, number]) do
        {:ok, remote_issue} ->
          {:cont, {:ok, [remote_issue | snapshots], unknowns}}

        {:error, reason} when allow_unknown? ->
          case definitive_unknown_reference(reason) do
            {:ok, state} -> {:cont, {:ok, snapshots, Map.put(unknowns, number, state)}}
            :error -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, snapshots, unknowns} -> {:ok, Enum.reverse(snapshots), unknowns}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recently_checked_unknown_numbers(repository_id) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@unknown_reference_recheck_seconds, :second)
      |> DateTime.truncate(:microsecond)

    IssueDependency
    |> join(:inner, [dependency], issue in Issue, on: issue.id == dependency.issue_id)
    |> where(
      [dependency, issue],
      issue.repository_id == ^repository_id and is_nil(dependency.blocking_issue_id) and
        dependency.lookup_state in ["missing", "pull_request"] and
        dependency.lookup_checked_at > ^cutoff
    )
    |> select([dependency, _issue], dependency.blocking_issue_number)
    |> Repo.all()
    |> MapSet.new()
  end

  defp record_unknown_references(repository, unknown_references, now) do
    issue_ids =
      Issue
      |> where([issue], issue.repository_id == ^repository.id)
      |> select([issue], issue.id)

    Enum.each(unknown_references, fn {number, state} ->
      IssueDependency
      |> where(
        [dependency],
        dependency.issue_id in subquery(issue_ids) and
          dependency.blocking_issue_number == ^number and
          is_nil(dependency.blocking_issue_id)
      )
      |> Repo.update_all(set: [lookup_state: state, lookup_checked_at: now])
    end)
  end

  defp definitive_unknown_reference({:github_http_error, 404, _message, _retry_delay}),
    do: {:ok, "missing"}

  defp definitive_unknown_reference(:github_item_is_pull_request), do: {:ok, "pull_request"}
  defp definitive_unknown_reference(_reason), do: :error

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
