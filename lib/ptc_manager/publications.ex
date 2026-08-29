defmodule PtcManager.Publications do
  @moduledoc "Durable, fenced state transitions for verified implementation PRs."

  import Ecto.Query

  alias PtcManager.Operations

  alias PtcManager.Operations.{
    AuditEvent,
    Job,
    PrPublication,
    Repository,
    WorktreeAllocation
  }

  alias PtcManager.Repo

  def next_open_for_status do
    PrPublication
    |> join(:inner, [publication], job in Job, on: job.id == publication.job_id)
    |> where(
      [publication, job],
      publication.state == "published" and job.state == "pr_open" and
        (is_nil(publication.pr_state) or publication.pr_state == "open")
    )
    |> order_by([publication], asc: publication.pr_checked_at, asc: publication.published_at)
    |> limit(1)
    |> preload([_publication, job], job: {job, [:issue, :repository]})
    |> Repo.one()
  end

  def claim_next(now \\ now()) do
    candidate =
      PrPublication
      |> eligible(now)
      |> order_by([publication],
        asc: publication.next_attempt_at,
        asc: publication.inserted_at,
        asc: publication.id
      )
      |> limit(1)
      |> Repo.one()

    case candidate do
      nil -> {:ok, nil}
      publication -> claim(publication.id, now)
    end
  end

  def claim(publication_id, now \\ now()) when is_integer(publication_id) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    timeout_ms = Application.get_env(:ptc_manager, :publication_claim_timeout_ms, 180_000)
    expires_at = DateTime.add(now, timeout_ms, :millisecond)

    outcome =
      Repo.transaction(fn ->
        publication =
          PrPublication
          |> preload(job: :repository)
          |> Repo.get!(publication_id)

        max_attempts = Application.get_env(:ptc_manager, :publication_max_attempts, 5)

        if eligible_record?(publication, now) and publication.attempt_count >= max_attempts do
          block_exhausted!(publication, now)
          {:exhausted, load(publication.id)}
        else
          {updated, _rows} =
            PrPublication
            |> where([candidate], candidate.id == ^publication_id)
            |> eligible(now)
            |> Repo.update_all(
              set: [
                state: "publishing",
                attempt_token: token,
                attempt_expires_at: expires_at,
                last_error: nil,
                updated_at: now
              ],
              inc: [attempt_count: 1]
            )

          if updated != 1, do: Repo.rollback(:publication_already_claimed)

          claimed = Repo.get!(PrPublication, publication_id)

          {job_updated, _rows} =
            Job
            |> where(
              [job],
              job.id == ^claimed.job_id and
                job.state in ["ready_for_pr", "publishing_pr"] and
                job.fencing_token == ^claimed.fencing_token and
                job.branch_name == ^claimed.branch_name and
                job.result_base_sha == ^claimed.base_sha and
                job.result_head_sha == ^claimed.head_sha and
                job.result_diff_digest == ^claimed.diff_digest
            )
            |> Repo.update_all(set: [state: "publishing_pr", updated_at: now])

          if job_updated != 1, do: Repo.rollback(:stale_verified_result)

          insert_audit!(%{
            actor: "coordinator",
            action: "pr_publication.claimed",
            target_type: "pr_publication",
            target_id: claimed.id,
            details: %{
              "attempt" => claimed.attempt_count,
              "fencing_token" => claimed.fencing_token,
              "head_sha" => claimed.head_sha
            }
          })

          {:claimed, load(claimed.id)}
        end
      end)

    case outcome do
      {:ok, {:claimed, claimed}} ->
        notify({:ok, claimed})

      {:ok, {:exhausted, _publication}} ->
        Operations.notify_changed(__MODULE__)
        {:error, :publication_attempts_exhausted}

      other ->
        notify(other)
    end
  end

  def renew_claim(publication_id, fencing_token, attempt_token, now \\ now())
      when is_integer(publication_id) and is_integer(fencing_token) and
             is_binary(attempt_token) do
    timeout_ms = Application.get_env(:ptc_manager, :publication_claim_timeout_ms, 180_000)
    expires_at = DateTime.add(now, timeout_ms, :millisecond)

    {updated, _rows} =
      PrPublication
      |> where(
        [publication],
        publication.id == ^publication_id and publication.state == "publishing" and
          publication.fencing_token == ^fencing_token and
          publication.attempt_token == ^attempt_token and
          not is_nil(publication.attempt_expires_at) and publication.attempt_expires_at > ^now
      )
      |> Repo.update_all(set: [attempt_expires_at: expires_at, updated_at: now])

    if updated == 1, do: :ok, else: {:error, :publication_claim_expired}
  end

  def complete(publication_id, fencing_token, attempt_token, result)
      when is_integer(publication_id) and is_integer(fencing_token) and
             is_binary(attempt_token) and is_map(result) do
    now = now()

    outcome =
      if valid_result?(result) do
        Repo.transaction(fn ->
          publication = Repo.get!(PrPublication, publication_id)

          cond do
            published_matches?(publication, fencing_token, result) ->
              load(publication.id)

            true ->
              {updated, _rows} =
                PrPublication
                |> where(
                  [candidate],
                  candidate.id == ^publication_id and candidate.state == "publishing" and
                    candidate.fencing_token == ^fencing_token and
                    candidate.attempt_token == ^attempt_token and
                    not is_nil(candidate.attempt_expires_at) and
                    candidate.attempt_expires_at > ^now and
                    candidate.head_sha == ^result.head_sha
                )
                |> Repo.update_all(
                  set: [
                    state: "published",
                    pr_number: result.pr_number,
                    pr_url: result.pr_url,
                    remote_head_sha: result.head_sha,
                    published_at: now,
                    pr_state: "open",
                    pr_checked_at: now,
                    attempt_expires_at: nil,
                    next_attempt_at: nil,
                    last_error: nil,
                    updated_at: now
                  ]
                )

              if updated != 1,
                do: Repo.rollback(attempt_failure(publication, fencing_token, attempt_token, now))

              {job_updated, _rows} =
                Job
                |> where(
                  [job],
                  job.id == ^publication.job_id and job.state == "publishing_pr" and
                    job.fencing_token == ^fencing_token and
                    job.result_head_sha == ^result.head_sha
                )
                |> Repo.update_all(set: [state: "pr_open", last_error: nil, updated_at: now])

              if job_updated != 1, do: Repo.rollback(:stale_verified_result)

              WorktreeAllocation
              |> where(
                [allocation],
                allocation.job_id == ^publication.job_id and
                  allocation.state not in ["cleaning", "removed"]
              )
              |> Repo.update_all(
                set: [
                  state: "warm",
                  head_sha: result.head_sha,
                  pr_number: result.pr_number,
                  pr_url: result.pr_url,
                  last_used_at: now,
                  last_error: nil,
                  updated_at: now
                ]
              )

              insert_audit!(%{
                actor: "github-broker",
                action: "pr_publication.published",
                target_type: "pr_publication",
                target_id: publication.id,
                details: %{
                  "fencing_token" => fencing_token,
                  "head_sha" => result.head_sha,
                  "pr_number" => result.pr_number,
                  "pr_url" => result.pr_url
                }
              })

              load(publication.id)
          end
        end)
      else
        {:error, :invalid_publication_result}
      end

    notify(outcome)
  end

  def fail(publication_id, fencing_token, attempt_token, disposition, reason)
      when disposition in [:retry, :blocked] do
    now = now()
    message = bounded_error(reason)

    outcome =
      Repo.transaction(fn ->
        publication = Repo.get!(PrPublication, publication_id)
        max_attempts = Application.get_env(:ptc_manager, :publication_max_attempts, 5)
        requested_delay_ms = requested_retry_delay_ms(reason)
        consumes_budget = is_nil(requested_delay_ms)

        final_disposition =
          if consumes_budget and publication.attempt_count >= max_attempts,
            do: :blocked,
            else: disposition

        state = if final_disposition == :retry, do: "queued", else: "blocked"
        job_state = if final_disposition == :retry, do: "ready_for_pr", else: "publish_blocked"

        next_attempt_at =
          if final_disposition == :retry do
            delay_ms = requested_delay_ms || retry_delay_ms(publication.attempt_count)
            DateTime.add(now, delay_ms, :millisecond)
          end

        attempt_count =
          if is_integer(requested_delay_ms),
            do: max(publication.attempt_count - 1, 0),
            else: publication.attempt_count

        {updated, _rows} =
          PrPublication
          |> where(
            [candidate],
            candidate.id == ^publication_id and candidate.state == "publishing" and
              candidate.fencing_token == ^fencing_token and
              candidate.attempt_token == ^attempt_token and
              not is_nil(candidate.attempt_expires_at) and candidate.attempt_expires_at > ^now
          )
          |> Repo.update_all(
            set: [
              state: state,
              attempt_count: attempt_count,
              attempt_expires_at: nil,
              next_attempt_at: next_attempt_at,
              last_error: message,
              updated_at: now
            ]
          )

        if updated != 1,
          do: Repo.rollback(attempt_failure(publication, fencing_token, attempt_token, now))

        {job_updated, _rows} =
          Job
          |> where(
            [job],
            job.id == ^publication.job_id and job.state == "publishing_pr" and
              job.fencing_token == ^fencing_token
          )
          |> Repo.update_all(set: [state: job_state, last_error: message, updated_at: now])

        if job_updated != 1, do: Repo.rollback(:stale_verified_result)

        insert_audit!(%{
          actor: "github-broker",
          action:
            if(final_disposition == :retry,
              do: "pr_publication.retry_scheduled",
              else: "pr_publication.blocked"
            ),
          target_type: "pr_publication",
          target_id: publication.id,
          details: %{
            "attempt" => publication.attempt_count,
            "reason" => message,
            "next_attempt_at" => next_attempt_at && DateTime.to_iso8601(next_attempt_at)
          }
        })

        load(publication.id)
      end)

    notify(outcome)
  end

  def retry_blocked(publication_id, actor) when is_integer(publication_id) and is_binary(actor) do
    now = now()

    outcome =
      Repo.transaction(fn ->
        publication = Repo.get!(PrPublication, publication_id)

        {updated, _rows} =
          PrPublication
          |> where([candidate], candidate.id == ^publication_id and candidate.state == "blocked")
          |> Repo.update_all(
            set: [
              state: "queued",
              next_attempt_at: now,
              attempt_token: nil,
              attempt_expires_at: nil,
              attempt_count: 0,
              last_error: nil,
              updated_at: now
            ]
          )

        if updated != 1, do: Repo.rollback(:publication_not_blocked)

        {job_updated, _rows} =
          Job
          |> where(
            [job],
            job.id == ^publication.job_id and job.state == "publish_blocked" and
              job.fencing_token == ^publication.fencing_token
          )
          |> Repo.update_all(set: [state: "ready_for_pr", last_error: nil, updated_at: now])

        if job_updated != 1, do: Repo.rollback(:stale_verified_result)

        insert_audit!(%{
          actor: actor,
          action: "pr_publication.retry_requested",
          target_type: "pr_publication",
          target_id: publication.id,
          details: %{"head_sha" => publication.head_sha}
        })

        load(publication.id)
      end)

    notify(outcome)
  end

  def record_remote_status(publication_id, result)
      when is_integer(publication_id) and is_map(result) do
    now = now()

    outcome =
      if valid_remote_status?(result) do
        Repo.transaction(fn ->
          publication = Repo.get!(PrPublication, publication_id)
          job = Repo.get!(Job, publication.job_id)
          repository = Repo.get!(Repository, job.repository_id)

          cond do
            publication.state != "published" or job.state != "pr_open" ->
              Repo.rollback(:publication_not_open)

            not intended_base?(result, repository) ->
              message = "GitHub reports a different pull-request base."

              publication
              |> PrPublication.changeset(%{
                state: "blocked",
                pr_state: result.state,
                remote_base_sha: result.base_sha,
                pr_checked_at: now,
                last_error: message
              })
              |> Repo.update!()

              job
              |> Job.changeset(%{state: "publish_blocked", last_error: message})
              |> Repo.update!()

              mark_worktree_attention(job.id, message, now)

              insert_status_audit!(publication, "pr_publication.base_changed", result, now)
              load(publication.id)

            result.head_sha != publication.remote_head_sha ->
              message = "GitHub reports a different pull-request head commit."

              publication
              |> PrPublication.changeset(%{
                state: "blocked",
                pr_state: result.state,
                remote_base_sha: result.base_sha,
                pr_checked_at: now,
                last_error: message
              })
              |> Repo.update!()

              job
              |> Job.changeset(%{state: "publish_blocked", last_error: message})
              |> Repo.update!()

              mark_worktree_attention(job.id, message, now)

              insert_status_audit!(publication, "pr_publication.head_changed", result, now)
              load(publication.id)

            result.state == "open" ->
              publication
              |> PrPublication.changeset(%{
                pr_state: "open",
                remote_base_sha: result.base_sha,
                pr_checked_at: now,
                pr_url: result.pr_url,
                last_error: nil
              })
              |> Repo.update!()

              WorktreeAllocation
              |> where(
                [allocation],
                allocation.job_id == ^job.id and allocation.state in ["warm", "reclaimable"]
              )
              |> Repo.update_all(
                set: [
                  state: "reclaimable",
                  head_sha: result.head_sha,
                  pr_url: result.pr_url,
                  last_used_at: now,
                  last_error: nil,
                  updated_at: now
                ]
              )

              load(publication.id)

            result.state in ["merged", "closed"] ->
              publication
              |> PrPublication.changeset(%{
                pr_state: result.state,
                remote_base_sha: result.base_sha,
                pr_checked_at: now,
                pr_url: result.pr_url,
                last_error: nil
              })
              |> Repo.update!()

              terminal_state = if result.state == "merged", do: "done", else: "cancelled"

              job
              |> Job.changeset(%{
                state: terminal_state,
                ended_at: now,
                last_error: nil
              })
              |> Repo.update!()

              WorktreeAllocation
              |> where(
                [allocation],
                allocation.job_id == ^job.id and
                  allocation.state not in ["cleaning", "removed"]
              )
              |> Repo.update_all(
                set: [state: "terminal", last_used_at: now, last_error: nil, updated_at: now]
              )

              insert_status_audit!(
                publication,
                "pr_publication.#{result.state}",
                result,
                now
              )

              load(publication.id)
          end
        end)
      else
        {:error, :invalid_pull_request_status}
      end

    notify(outcome)
  end

  def record_status_error(publication_id, reason) when is_integer(publication_id) do
    now = now()
    message = bounded_error(reason)

    outcome =
      PrPublication
      |> where(
        [publication],
        publication.id == ^publication_id and publication.state == "published"
      )
      |> Repo.update_all(set: [pr_checked_at: now, last_error: message, updated_at: now])
      |> case do
        {1, _rows} -> {:ok, Repo.get!(PrPublication, publication_id)}
        {0, _rows} -> {:error, :publication_not_open}
      end

    notify(outcome)
  end

  defp load(id) do
    PrPublication
    |> preload(job: [:issue, :repository, :worktree_allocation])
    |> Repo.get!(id)
  end

  defp eligible(query, now) do
    where(
      query,
      [publication],
      publication.source == "broker" and
        ((publication.state == "queued" and
            (is_nil(publication.next_attempt_at) or publication.next_attempt_at <= ^now)) or
           (publication.state == "publishing" and not is_nil(publication.attempt_expires_at) and
              publication.attempt_expires_at <= ^now))
    )
  end

  defp eligible_record?(publication, now) do
    publication.source == "broker" and
      ((publication.state == "queued" and
          (is_nil(publication.next_attempt_at) or
             DateTime.compare(publication.next_attempt_at, now) != :gt)) or
         (publication.state == "publishing" and not is_nil(publication.attempt_expires_at) and
            DateTime.compare(publication.attempt_expires_at, now) != :gt))
  end

  defp block_exhausted!(publication, now) do
    message = "Publication retry budget was exhausted after interrupted attempts."

    publication
    |> PrPublication.changeset(%{
      state: "blocked",
      attempt_token: nil,
      attempt_expires_at: nil,
      next_attempt_at: nil,
      last_error: message
    })
    |> Repo.update!()

    {job_updated, _rows} =
      Job
      |> where(
        [job],
        job.id == ^publication.job_id and job.state in ["ready_for_pr", "publishing_pr"] and
          job.fencing_token == ^publication.fencing_token
      )
      |> Repo.update_all(set: [state: "publish_blocked", last_error: message, updated_at: now])

    if job_updated != 1, do: Repo.rollback(:stale_verified_result)

    insert_audit!(%{
      actor: "coordinator",
      action: "pr_publication.blocked",
      target_type: "pr_publication",
      target_id: publication.id,
      details: %{
        "attempt" => publication.attempt_count,
        "reason" => message
      }
    })
  end

  defp valid_result?(result) do
    is_integer(result[:pr_number]) and result.pr_number > 0 and is_binary(result[:pr_url]) and
      github_url?(result.pr_url) and
      is_binary(result[:head_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.head_sha)
  end

  defp valid_remote_status?(result) do
    result[:state] in ["open", "merged", "closed"] and is_binary(result[:pr_url]) and
      github_url?(result.pr_url) and is_binary(result[:head_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.head_sha) and
      is_binary(result[:base_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.base_sha) and
      is_binary(result[:base_ref]) and is_binary(result[:base_repository])
  end

  defp intended_base?(result, repository) do
    result.base_ref == repository.default_branch and
      String.downcase(result.base_repository) ==
        String.downcase("#{repository.github_owner}/#{repository.github_name}")
  end

  defp github_url?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: path} when is_binary(path) -> true
      _uri -> false
    end
  end

  defp published_matches?(publication, fencing_token, result) do
    publication.state == "published" and publication.fencing_token == fencing_token and
      publication.pr_number == result.pr_number and publication.pr_url == result.pr_url and
      publication.remote_head_sha == result.head_sha
  end

  defp attempt_failure(publication, fencing_token, attempt_token, now) do
    cond do
      publication.fencing_token != fencing_token -> :stale_fencing_token
      publication.attempt_token != attempt_token -> :stale_publication_attempt
      publication.state != "publishing" -> :invalid_publication_state
      is_nil(publication.attempt_expires_at) -> :publication_claim_expired
      DateTime.compare(publication.attempt_expires_at, now) != :gt -> :publication_claim_expired
      true -> :publication_race
    end
  end

  defp retry_delay_ms(attempt_count) do
    base = Application.get_env(:ptc_manager, :publication_retry_base_ms, 5_000)
    max_delay = Application.get_env(:ptc_manager, :publication_retry_max_ms, 300_000)
    min(base * Integer.pow(2, max(attempt_count - 1, 0)), max_delay)
  end

  defp requested_retry_delay_ms({:after, delay_ms, {:github_http_error, _, _, delay_ms}})
       when is_integer(delay_ms) and delay_ms > 0,
       do: delay_ms

  defp requested_retry_delay_ms(_reason), do: nil

  defp insert_audit!(attrs), do: %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert!()

  defp mark_worktree_attention(job_id, message, now) do
    WorktreeAllocation
    |> where(
      [allocation],
      allocation.job_id == ^job_id and allocation.state not in ["cleaning", "removed"]
    )
    |> Repo.update_all(
      set: [state: "attention", last_used_at: now, last_error: message, updated_at: now]
    )
  end

  defp insert_status_audit!(publication, action, result, now) do
    insert_audit!(%{
      actor: "github-reconciler",
      action: action,
      target_type: "pr_publication",
      target_id: publication.id,
      details: %{
        "head_sha" => result.head_sha,
        "pr_state" => result.state,
        "observed_at" => DateTime.to_iso8601(now)
      }
    })
  end

  defp bounded_error(reason), do: reason |> inspect(limit: 20) |> String.slice(0, 500)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp notify({:ok, _value} = outcome) do
    Operations.notify_changed(__MODULE__)
    outcome
  end

  defp notify(outcome), do: outcome
end
