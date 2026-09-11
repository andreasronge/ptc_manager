defmodule PtcManager.GitHub.Sync do
  @moduledoc "Persists complete read-only GitHub issue snapshots transactionally."

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

    Operations.with_repository_lifecycle_lock(repository.id, fn ->
      case Operations.get_repository(repository.id) do
        nil -> {:ok, :repository_removed}
        current_repository -> do_sync_repository(current_repository, client, opts)
      end
    end)
  end

  def sync_issue(%Repository{} = repository, number, opts \\ [])
      when is_integer(number) and number > 0 do
    client = Keyword.get(opts, :client, Application.fetch_env!(:ptc_manager, :github_client))

    Operations.with_repository_lifecycle_lock(repository.id, fn ->
      case Operations.get_repository(repository.id) do
        nil ->
          {:ok, :repository_removed}

        current_repository ->
          case Gateway.call(client, :get_issue, [current_repository, number]) do
            {:ok, remote_issue} -> persist_issue(current_repository, remote_issue, opts)
            {:error, reason} -> {:error, reason}
          end
      end
    end)
  end

  defp do_sync_repository(repository, client, opts) do
    syncing_repository = mark_syncing(repository)

    with {:ok, remote_issues} <- Gateway.call(client, :list_open_issues, [syncing_repository]),
         {:ok, missing_issues} <- fetch_missing_issues(syncing_repository, remote_issues, client) do
      persist_snapshot(
        syncing_repository,
        remote_issues,
        missing_issues,
        viewer_login(client),
        Operations.read_repository_labels(client, syncing_repository),
        opts
      )
    else
      {:error, reason} -> mark_failed(syncing_repository, reason)
    end
  end

  # Who PtcManager reads GitHub as. A failure here must not fail the sync: the
  # console simply shows no author badges until the identity is known again.
  defp viewer_login(client) do
    {module, arity} = if is_atom(client), do: {client, 0}, else: {client.__struct__, 1}

    if Code.ensure_loaded?(module) and function_exported?(module, :viewer_login, arity) do
      case Gateway.call(client, :viewer_login, []) do
        {:ok, login} when is_binary(login) and login != "" -> login
        _unavailable -> nil
      end
    end
  end

  defp persist_snapshot(
         repository,
         remote_issues,
         missing_issues,
         viewer_login,
         label_names,
         opts
       ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.transaction(fn ->
        normalized =
          Enum.map(remote_issues ++ missing_issues, &IssueSnapshot.normalize!(&1, repository))

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

        dependency_context = dependency_context()

        Enum.each(normalized, fn attrs ->
          replace_dependencies(
            Map.fetch!(synchronized_issues, attrs.number),
            attrs.blocking_issues,
            dependency_context
          )
        end)

        closed_count = Enum.count(missing_issues, &(&1["state"] == "closed"))

        synced_repository =
          repository
          |> Repository.changeset(
            %{
              sync_status: "ok",
              last_synced_at: now,
              last_sync_error: nil,
              github_viewer_login: viewer_login || repository.github_viewer_login
            }
            |> put_label_names(label_names, now)
          )
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
        admit_after_sync(summary, opts)
        Operations.notify_changed(__MODULE__)
        {:ok, summary}

      {:error, reason} ->
        mark_failed(repository, reason)
    end
  rescue
    error -> mark_failed(repository, error)
  end

  # Admission runs only after a successful read. A postflight that re-syncs the
  # structure of a collection passes `admit: false`, because a member must not
  # be admitted in the middle of a structure check; the caller reconciles once
  # afterwards instead.
  defp admit_after_sync(summary, opts) do
    if Keyword.get(opts, :admit, true) do
      PtcManager.AutoImplementation.reconcile(
        summary.repository.id,
        Map.get(summary, :issue_number)
      )
    end
  end

  defp put_label_names(attrs, nil, _now), do: attrs

  defp put_label_names(attrs, names, now) do
    Map.merge(attrs, %{github_label_names: %{"names" => names}, github_labels_checked_at: now})
  end

  defp persist_issue(repository, remote_issue, opts) do
    result =
      Repo.transaction(fn ->
        attrs = IssueSnapshot.normalize!(remote_issue, repository)

        existing = Repo.get_by(Issue, repository_id: repository.id, number: attrs.number)
        changed? = upsert_issue(existing, attrs) == :changed

        synchronized_issues =
          Issue
          |> where([issue], issue.repository_id == ^repository.id)
          |> Repo.all()
          |> Map.new(&{&1.number, &1})

        replace_dependencies(
          Map.fetch!(synchronized_issues, attrs.number),
          attrs.blocking_issues,
          dependency_context()
        )

        %{repository: repository, issue_number: attrs.number, changed?: changed?}
      end)

    case result do
      {:ok, summary} ->
        admit_after_sync(summary, opts)
        Operations.notify_changed(__MODULE__)
        {:ok, summary}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  # Fields GitHub reports that are deliberately outside the content digest, so
  # they can never make a stored proposal stale.
  @projection_fields [
    :github_created_at,
    :github_author_login,
    :github_labels,
    :github_comment_count,
    :comments_checked_at
  ]

  defp upsert_issue(nil, attrs) do
    %Issue{} |> Issue.changeset(attrs) |> Repo.insert!()
    :changed
  end

  defp upsert_issue(%Issue{} = issue, attrs) do
    if canonical_unchanged?(issue, attrs) do
      # No content change, so this is not a change a maintainer has to look at.
      # The projection still has to land, or a row written before those columns
      # existed would keep its defaults until GitHub happened to touch it.
      persist_projection(issue, attrs)
      :unchanged
    else
      issue |> Issue.changeset(attrs) |> Repo.update!()
      :changed
    end
  end

  defp canonical_unchanged?(
         %Issue{
           content_digest: digest,
           dependency_overflow: overflow,
           dependency_unknown_count: unknown_count,
           dependencies_projected: true,
           github_assignment_projected: true,
           structure_projected: true
         },
         %{
           content_digest: digest,
           dependency_overflow: overflow,
           dependency_unknown_count: unknown_count,
           dependencies_projected: true,
           github_assignment_projected: true,
           structure_projected: true
         }
       ),
       do: true

  defp canonical_unchanged?(_issue, _attrs), do: false

  defp persist_projection(issue, attrs) do
    projection = Map.take(attrs, @projection_fields)

    if Enum.any?(projection, fn {field, value} -> Map.fetch!(issue, field) != value end) do
      issue |> Issue.changeset(projection) |> Repo.update!()
    end

    :ok
  end

  defp replace_dependencies(issue, blockers, context) do
    existing =
      IssueDependency
      |> where([dependency], dependency.issue_id == ^issue.id)
      |> Repo.all()
      |> Map.new(&{{&1.blocking_repository_full_name, &1.blocking_issue_number}, &1})

    blocker_keys = MapSet.new(blockers, &{&1.repository_full_name, &1.number})

    stale_ids =
      existing
      |> Enum.reject(fn {key, _dependency} -> MapSet.member?(blocker_keys, key) end)
      |> Enum.map(fn {_key, dependency} -> dependency end)
      |> Enum.map(& &1.id)

    if stale_ids != [] do
      IssueDependency
      |> where([dependency], dependency.id in ^stale_ids)
      |> Repo.delete_all()
    end

    Enum.each(blockers, fn blocker ->
      blocking_repository = Map.get(context.repositories, blocker.repository_full_name)

      blocking_issue =
        blocking_repository &&
          Map.get(context.issues, {blocking_repository.id, blocker.number})

      attrs = %{
        issue_id: issue.id,
        blocking_issue_id: blocking_issue && blocking_issue.id,
        blocking_repository_id: blocking_repository && blocking_repository.id,
        blocking_repository_full_name: blocker.repository_full_name,
        blocking_github_id: blocker.github_id,
        blocking_node_id: blocker.node_id,
        blocking_issue_number: blocker.number,
        blocking_title: blocker.title,
        blocking_html_url: blocker.html_url,
        blocking_state: blocker.state,
        blocking_state_reason: blocker.state_reason,
        lookup_state: if(blocker.state in ["open", "closed"], do: "resolved", else: "pending"),
        lookup_checked_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }

      case Map.get(existing, {blocker.repository_full_name, blocker.number}) do
        nil ->
          %IssueDependency{} |> IssueDependency.changeset(attrs) |> Repo.insert!()

        dependency ->
          dependency |> IssueDependency.changeset(attrs) |> Repo.update!()
      end
    end)
  end

  defp dependency_context do
    repositories =
      Repository
      |> Repo.all()
      |> Map.new(fn repository ->
        {String.downcase("#{repository.github_owner}/#{repository.github_name}"), repository}
      end)

    issues = Issue |> Repo.all() |> Map.new(&{{&1.repository_id, &1.number}, &1})
    %{repositories: repositories, issues: issues}
  end

  defp fetch_missing_issues(repository, remote_issues, client) do
    open_numbers = MapSet.new(remote_issues, & &1["number"])

    local_issues =
      Issue
      |> where([issue], issue.repository_id == ^repository.id)
      |> Repo.all()

    missing_open_numbers =
      local_issues
      |> Enum.filter(&(&1.state == "open" and not MapSet.member?(open_numbers, &1.number)))
      |> Enum.map(& &1.number)

    fetch_issue_numbers(missing_open_numbers, repository, client)
  end

  defp fetch_issue_numbers(numbers, repository, client) do
    Enum.reduce_while(numbers, {:ok, []}, fn number, {:ok, snapshots} ->
      case Gateway.call(client, :get_issue, [repository, number]) do
        {:ok, remote_issue} ->
          {:cont, {:ok, [remote_issue | snapshots]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, reason} -> {:error, reason}
    end
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
