defmodule PtcManager.Publications do
  @moduledoc "Durable, fenced state transitions for verified implementation PRs."

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.GitHub.{LinkedIssues, PullRequestClient}
  alias PtcManager.Herdr.StateRevision

  alias PtcManager.Operations.{
    AgentAction,
    AgentRun,
    AuditEvent,
    Job,
    MergeApproval,
    PrAnalysis,
    PrPublication,
    Repository,
    WorktreeAllocation
  }

  alias PtcManager.Repo
  alias PtcManager.RepoTransaction

  @agent_reconciliation_job_states ~w(starting working idle blocked reconciling awaiting_reconciliation verifying_result ready_for_pr publishing_pr pr_open)
  @external_missing_marker "GitHub open-PR listing omitted this PR once; waiting for confirmation."
  @external_adoption_deferred "The matching pull request has an active external action. Adoption will retry after that action finishes."

  @doc "Imports GitHub's complete open-PR snapshot without inventing implementation jobs."
  def sync_external_open_pull_requests(%Repository{} = repository, pulls) when is_list(pulls) do
    now = now()

    outcome =
      if Enum.all?(pulls, &valid_external_status?/1) do
        RepoTransaction.immediate(fn ->
          managed_numbers = managed_pr_numbers(repository.id)
          managed_heads = managed_pr_heads(repository)

          external_pulls =
            Enum.reject(pulls, fn pull ->
              pull.pr_number in managed_numbers or
                managed_head?(managed_heads, pull.head_repository, pull.head_ref)
            end)

          Enum.each(external_pulls, &upsert_external_pull!(repository, &1, now))

          open_numbers = MapSet.new(external_pulls, & &1.pr_number)

          stale_query =
            PrPublication
            |> where(
              [publication],
              publication.repository_id == ^repository.id and publication.source == "external" and
                publication.pr_state == "open"
            )

          stale_query =
            if MapSet.size(open_numbers) == 0,
              do: stale_query,
              else:
                where(
                  stale_query,
                  [publication],
                  publication.pr_number not in ^MapSet.to_list(open_numbers)
                )

          first_absence =
            where(
              stale_query,
              [publication],
              is_nil(publication.last_error) or
                publication.last_error != ^@external_missing_marker
            )

          Repo.update_all(first_absence,
            set: [last_error: @external_missing_marker, updated_at: now]
          )

          %{open_count: length(external_pulls), closed_count: 0}
        end)
      else
        {:error, :invalid_external_pull_request_snapshot}
      end

    notify(outcome)
  end

  def external_missing_candidates(%Repository{id: repository_id}, pulls) when is_list(pulls) do
    listed_numbers = Enum.map(pulls, & &1.pr_number)

    query =
      PrPublication
      |> where(
        [publication],
        publication.repository_id == ^repository_id and publication.source == "external" and
          publication.pr_state == "open" and publication.last_error == ^@external_missing_marker
      )

    query =
      if listed_numbers == [],
        do: query,
        else: where(query, [publication], publication.pr_number not in ^listed_numbers)

    Repo.all(query) |> Repo.preload(:repository)
  end

  @doc """
  Managed pull requests whose retrospective proposed work nobody has tracked.

  The signal is the `ptc:follow-up` label the implementation agent adds to its
  own pull request. It survives the merge, because a suggestion is an issue
  waiting to be decided, not a delivery step.
  """
  def follow_up_candidates do
    PrPublication
    |> where(
      [publication],
      publication.source in ["broker", "agent"] and not is_nil(publication.job_id) and
        is_nil(publication.follow_up_dismissed_at)
    )
    |> order_by([publication], desc: publication.pr_checked_at, desc: publication.id)
    |> preload(job: [:repository, :issue])
    |> Repo.all()
    |> Enum.filter(&PrPublication.follow_up_suggested?/1)
    |> reject_finished_retrospectives()
  end

  @doc """
  Removes one follow-up suggestion from Planning without touching GitHub.

  Only a pull request that is currently a candidate can be dismissed. Stamping
  one that never suggested anything would hide a later `ptc:follow-up` on it for
  good, and the id arrives from a browser event.
  """
  def dismiss_follow_up(publication_id, actor)
      when is_integer(publication_id) and is_binary(actor) and actor != "" do
    now = now()

    outcome =
      RepoTransaction.immediate(fn ->
        publication =
          Enum.find(follow_up_candidates(), &(&1.id == publication_id)) ||
            Repo.rollback(:not_a_follow_up_candidate)

        updated =
          publication
          |> PrPublication.changeset(%{follow_up_dismissed_at: now})
          |> Repo.update!()

        insert_audit!(%{
          actor: actor,
          action: "pull_request.follow_up_dismissed",
          target_type: "pr_publication",
          target_id: publication_id,
          details: %{"pr_number" => publication.pr_number}
        })

        updated
      end)

    notify(outcome)
  end

  # A retrospective that ran and found nothing is not a suggestion any more.
  defp reject_finished_retrospectives([]), do: []

  defp reject_finished_retrospectives(publications) do
    ids = Enum.map(publications, & &1.id)

    finished =
      AgentAction
      |> where(
        [action],
        action.target_type == "pull_request" and action.target_id in ^ids and
          action.action_key == "pr_retrospective" and action.state == "done"
      )
      |> order_by([action], desc: action.id)
      |> Repo.all()
      |> Enum.reduce(%{}, &Map.put_new(&2, &1.target_id, &1))

    Enum.reject(publications, fn publication ->
      match?(%{}, Map.get(finished, publication.id)) and
        no_follow_ups?(Map.get(finished, publication.id))
    end)
  end

  defp no_follow_ups?(%{result_summary: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"outcome" => "no-followups"}} -> true
      _result -> false
    end
  end

  defp no_follow_ups?(_action), do: false

  def agent_reconciliation_needed? do
    Repo.exists?(
      from job in Job,
        where:
          job.publication_source == "agent" and
            job.state in ^@agent_reconciliation_job_states
    )
  end

  def next_agent_for_discovery(now \\ now()) do
    PrPublication
    |> join(:inner, [publication], job in Job, on: job.id == publication.job_id)
    |> where(
      [publication, job],
      publication.source == "agent" and publication.state == "queued" and
        job.state == "ready_for_pr" and
        (is_nil(publication.next_attempt_at) or publication.next_attempt_at <= ^now)
    )
    |> order_by([publication],
      asc: publication.next_attempt_at,
      asc: publication.inserted_at,
      asc: publication.id
    )
    |> limit(1)
    |> preload([_publication, job], job: {job, [:issue, :repository, :worktree_allocation]})
    |> Repo.one()
  end

  def next_open_for_status(include_external \\ true) do
    query =
      PrPublication
      |> where(
        [publication],
        (publication.state == "published" and
           (is_nil(publication.pr_state) or publication.pr_state == "open")) or
          (publication.state == "blocked" and publication.pr_state == "open")
      )

    query =
      if include_external,
        do: query,
        else: where(query, [publication], publication.source != "external")

    query
    |> order_by([publication], asc: publication.pr_checked_at, asc: publication.published_at)
    |> limit(1)
    |> preload([:repository, job: [:issue, :repository]])
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
      RepoTransaction.immediate(fn ->
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

  def record_pre_publication_gate(publication_id, fencing_token, attempt_token, evidence)
      when is_integer(publication_id) and is_integer(fencing_token) and
             is_binary(attempt_token) and is_map(evidence) do
    now = now()

    outcome =
      if valid_gate_evidence?(evidence) do
        RepoTransaction.immediate(fn ->
          publication = load(publication_id)

          with :ok <- active_publication_claim(publication, fencing_token, attempt_token, now),
               true <- evidence.verified_sha == publication.head_sha,
               true <- evidence.config_digest == publication.job.pre_publication_config_digest do
            job =
              publication.job
              |> Job.changeset(%{
                pre_publication_status: evidence.status,
                pre_publication_verified_sha: evidence.verified_sha,
                pre_publication_exit_status: evidence.exit_status,
                pre_publication_output: evidence.output,
                pre_publication_duration_ms: evidence.duration_ms,
                pre_publication_verified_at: now
              })
              |> Repo.update!()

            insert_audit!(%{
              actor: "coordinator",
              action: "pr_publication.pre_publication_gate_recorded",
              target_type: "pr_publication",
              target_id: publication.id,
              details: %{
                "status" => evidence.status,
                "verified_sha" => evidence.verified_sha,
                "exit_status" => evidence.exit_status,
                "duration_ms" => evidence.duration_ms,
                "output_truncated" => Map.get(evidence, :output_truncated, false),
                "config_digest" => evidence.config_digest
              }
            })

            %{publication | job: job}
          else
            false -> Repo.rollback(:stale_pre_publication_gate_evidence)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      else
        {:error, :invalid_pre_publication_gate_evidence}
      end

    notify(outcome)
  end

  def complete(publication_id, fencing_token, attempt_token, result)
      when is_integer(publication_id) and is_integer(fencing_token) and
             is_binary(attempt_token) and is_map(result) do
    now = now()

    outcome =
      if valid_result?(result) do
        RepoTransaction.immediate(fn ->
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
                  state: "waiting",
                  head_sha: result.head_sha,
                  pr_number: result.pr_number,
                  pr_url: result.pr_url,
                  last_used_at: now,
                  last_error: nil,
                  updated_at: now
                ]
              )

              mark_implementation_agent_waiting(publication.job_id, now)

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

  def record_agent_publication(publication_id, result)
      when is_integer(publication_id) and is_map(result) do
    now = now()

    outcome =
      if valid_agent_result?(result) do
        RepoTransaction.immediate(fn ->
          publication =
            PrPublication
            |> preload(job: [:issue, :repository, :worktree_allocation])
            |> Repo.get!(publication_id)

          job = publication.job
          repository = job.repository

          publication =
            adopt_matching_external_publication!(publication, job, repository, result, now)

          cond do
            publication.source != "agent" ->
              Repo.rollback(:wrong_publication_source)

            publication.state == "queued" and
                publication.last_error == @external_adoption_deferred ->
              load(publication.id)

            publication.state == "published" and
                published_matches?(publication, publication.fencing_token, result) ->
              load(publication.id)

            publication.state != "queued" or job.state != "ready_for_pr" ->
              Repo.rollback(:invalid_publication_state)

            result.head_ref != publication.branch_name ->
              block_agent_publication!(
                publication,
                job,
                result,
                "GitHub reports a different agent branch.",
                now
              )

            String.downcase(result.head_repository) !=
                String.downcase("#{repository.github_owner}/#{repository.github_name}") ->
              block_agent_publication!(
                publication,
                job,
                result,
                "GitHub reports the agent pull request from a different repository.",
                now
              )

            not intended_base?(result, repository) ->
              block_agent_publication!(
                publication,
                job,
                result,
                "GitHub reports a different pull-request base.",
                now
              )

            result.state == "open" and result.head_sha != publication.head_sha ->
              block_agent_publication!(
                publication,
                job,
                result,
                "GitHub reports a different agent branch head commit.",
                now
              )

            true ->
              publication
              |> PrPublication.changeset(
                Map.merge(
                  %{
                    state: "published",
                    pr_number: result.pr_number,
                    pr_url: result.pr_url,
                    remote_head_sha: result.head_sha,
                    remote_base_sha: result.base_sha,
                    published_at: now,
                    pr_state: result.state,
                    pr_checked_at: now,
                    title: Map.get(result, :title) || job.issue.title,
                    author_login: Map.get(result, :author_login),
                    head_ref: result.head_ref,
                    head_repository: result.head_repository,
                    next_attempt_at: nil,
                    last_error: nil
                  },
                  remote_status_attrs(result)
                )
              )
              |> Repo.update!()

              terminal? = result.state in ["merged", "closed"]

              job_state =
                case result.state do
                  "open" -> "pr_open"
                  "merged" -> "done"
                  "closed" -> "cancelled"
                end

              job
              |> Job.changeset(%{
                state: job_state,
                ended_at: if(terminal?, do: now),
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
                set: [
                  state: if(terminal?, do: "terminal", else: "waiting"),
                  head_sha: result.head_sha,
                  pr_number: result.pr_number,
                  pr_url: result.pr_url,
                  last_used_at: now,
                  last_error: nil,
                  updated_at: now
                ]
              )

              if terminal?,
                do: finish_retained_implementation_agent(job.id, result.state, now),
                else: mark_implementation_agent_waiting(job.id, now)

              insert_audit!(%{
                actor: "github-reconciler",
                action: "pr_publication.discovered",
                target_type: "pr_publication",
                target_id: publication.id,
                details: %{
                  "fencing_token" => publication.fencing_token,
                  "head_sha" => result.head_sha,
                  "pr_number" => result.pr_number,
                  "pr_url" => result.pr_url,
                  "pr_state" => result.state
                }
              })

              if terminal? do
                insert_status_audit!(
                  publication,
                  "pr_publication.#{result.state}",
                  result,
                  now
                )
              end

              load(publication.id)
          end
        end)
      else
        {:error, :invalid_pull_request_status}
      end

    notify(outcome)
  end

  def record_agent_discovery_retry(publication_id, reason, delay_ms)
      when is_integer(publication_id) and is_integer(delay_ms) and delay_ms > 0 do
    now = now()
    message = bounded_error(reason)
    next_attempt_at = DateTime.add(now, delay_ms, :millisecond)

    outcome =
      RepoTransaction.immediate(fn ->
        publication = Repo.get!(PrPublication, publication_id)
        job = Repo.get!(Job, publication.job_id)

        unless publication.source == "agent" and publication.state == "queued" and
                 job.state == "ready_for_pr",
               do: Repo.rollback(:invalid_publication_state)

        publication =
          publication
          |> PrPublication.changeset(%{
            attempt_count: publication.attempt_count + 1,
            next_attempt_at: next_attempt_at,
            last_error: message
          })
          |> Repo.update!()

        if publication.attempt_count >=
             Application.get_env(:ptc_manager, :publication_max_attempts, 5),
           do:
             block_agent_discovery!(
               publication,
               job,
               String.slice("PR discovery budget reached: " <> message, 0, 500),
               now
             ),
           else: publication
      end)

    notify(outcome)
  end

  def block_agent_discovery(publication_id, reason) when is_integer(publication_id) do
    now = now()
    message = bounded_error(reason)

    outcome =
      RepoTransaction.immediate(fn ->
        publication = Repo.get!(PrPublication, publication_id)
        job = Repo.get!(Job, publication.job_id)

        if publication.source != "agent" or publication.state != "queued" or
             job.state != "ready_for_pr" do
          Repo.rollback(:invalid_publication_state)
        end

        block_agent_discovery!(publication, job, message, now)
      end)

    notify(outcome)
  end

  defp block_agent_discovery!(publication, job, message, now) do
    publication
    |> PrPublication.changeset(%{
      state: "blocked",
      next_attempt_at: nil,
      last_error: message
    })
    |> Repo.update!()

    job |> Job.changeset(%{state: "publish_blocked", last_error: message}) |> Repo.update!()
    mark_worktree_attention(job.id, message, now)

    insert_audit!(%{
      actor: "github-reconciler",
      action: "pr_publication.discovery_blocked",
      target_type: "pr_publication",
      target_id: publication.id,
      details: %{"reason" => message}
    })

    load(publication.id)
  end

  def fail(publication_id, fencing_token, attempt_token, disposition, reason)
      when disposition in [:retry, :blocked] do
    now = now()
    message = bounded_error(reason)

    outcome =
      RepoTransaction.immediate(fn ->
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
      RepoTransaction.immediate(fn ->
        # The id arrives from a browser event, so a card the maintainer is
        # looking at may already be gone.
        publication =
          Repo.get(PrPublication, publication_id) || Repo.rollback(:publication_not_found)

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
        with {:ok, projection} <- remote_status_projection(publication_id) do
          transaction_result =
            RepoTransaction.immediate(fn ->
              reserve_remote_status_projection!(projection)

              publication = projection.publication
              job = projection.job
              repository = projection.repository

              cond do
                PrPublication.external?(publication) ->
                  record_external_remote_status!(publication, repository, result, now)

                not reconcilable_remote_status?(publication, job) ->
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
                  :ok

                # While an action that pushes to this pull request is queued,
                # running, or syncing, a head it pushed is verified by that action,
                # not fenced by the poller; the status still moves so the board
                # stays current.
                result.state == "open" and result.head_sha != publication.remote_head_sha and
                    projection.pushing_action_in_flight? ->
                  publication
                  |> PrPublication.changeset(
                    Map.merge(
                      %{pr_state: "open", remote_base_sha: result.base_sha, pr_checked_at: now},
                      remote_status_attrs(result)
                    )
                  )
                  |> Repo.update!()

                  :ok

                # A head the console never verified blocks the lineage once per
                # head: the first poll announces it and parks the job and worktree,
                # later polls only keep checks and mergeability current.
                result.state == "open" and result.head_sha != publication.remote_head_sha ->
                  message = "GitHub reports a different pull-request head commit."

                  announced? =
                    publication.state == "blocked" and
                      publication.observed_head_sha == result.head_sha

                  publication
                  |> PrPublication.changeset(
                    Map.merge(
                      %{
                        state: "blocked",
                        pr_state: result.state,
                        remote_base_sha: result.base_sha,
                        observed_head_sha: result.head_sha,
                        pr_checked_at: now,
                        last_error: message
                      },
                      remote_status_attrs(result)
                    )
                  )
                  |> Repo.update!()

                  unless announced? do
                    job
                    |> Job.changeset(%{state: "publish_blocked", last_error: message})
                    |> Repo.update!()

                    mark_worktree_attention(job.id, message, now)
                    insert_status_audit!(publication, "pr_publication.head_changed", result, now)
                  end

                  :ok

                result.state == "open" ->
                  publication
                  |> PrPublication.changeset(
                    Map.merge(
                      %{
                        pr_state: "open",
                        remote_base_sha: result.base_sha,
                        observed_head_sha: nil,
                        pr_checked_at: now,
                        pr_url: result.pr_url,
                        last_error: nil
                      },
                      remote_status_attrs(result)
                    )
                  )
                  |> Repo.update!()

                  WorktreeAllocation
                  |> where(
                    [allocation],
                    allocation.job_id == ^job.id and
                      allocation.state in ["warm", "waiting", "reclaimable"]
                  )
                  |> Repo.update_all(
                    set: [
                      state: "waiting",
                      head_sha: result.head_sha,
                      pr_url: result.pr_url,
                      last_used_at: now,
                      last_error: nil,
                      updated_at: now
                    ]
                  )

                  mark_implementation_agent_waiting(job.id, now)

                  :ok

                result.state in ["merged", "closed"] ->
                  publication
                  |> PrPublication.changeset(
                    Map.merge(
                      %{
                        state: "published",
                        pr_state: result.state,
                        remote_head_sha: result.head_sha,
                        remote_base_sha: result.base_sha,
                        pr_checked_at: now,
                        pr_url: result.pr_url,
                        last_error: nil
                      },
                      remote_status_attrs(result)
                    )
                  )
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

                  finish_retained_implementation_agent(job.id, result.state, now)

                  insert_status_audit!(
                    publication,
                    "pr_publication.#{result.state}",
                    result,
                    now
                  )

                  :ok
              end

              publication.id
            end)

          case transaction_result do
            {:ok, id} -> {:ok, load(id)}
            error -> error
          end
        end
      else
        {:error, :invalid_pull_request_status}
      end

    notify(outcome)
  end

  @doc "Records a newly pushed PR head only after its retained branch passes local verification."
  def record_repaired_status(publication_id, result, verified)
      when is_integer(publication_id) and is_map(result) and is_map(verified) do
    now = now()

    outcome =
      if valid_agent_result?(result) and valid_verified_result?(verified) do
        RepoTransaction.immediate(fn ->
          publication = Repo.get!(PrPublication, publication_id)
          job = Repo.get!(Job, publication.job_id)
          repository = Repo.get!(Repository, job.repository_id)

          cond do
            not repair_lineage_open?(publication, job) ->
              Repo.rollback(:publication_not_open)

            result.state != "open" ->
              Repo.rollback(:pull_request_not_open)

            not intended_base?(result, repository) ->
              Repo.rollback(:unexpected_pull_request_base)

            result.head_ref != publication.branch_name ->
              Repo.rollback(:unexpected_pull_request_branch)

            String.downcase(result.head_repository) !=
                String.downcase("#{repository.github_owner}/#{repository.github_name}") ->
              Repo.rollback(:unexpected_pull_request_repository)

            result.head_sha != verified.head_sha ->
              Repo.rollback(:repair_head_not_verified)

            true ->
              publication
              |> PrPublication.changeset(
                Map.merge(
                  %{
                    state: "published",
                    base_sha: verified.base_sha,
                    head_sha: verified.head_sha,
                    diff_digest: verified.diff_digest,
                    remote_head_sha: result.head_sha,
                    observed_head_sha: nil,
                    remote_base_sha: result.base_sha,
                    pr_state: "open",
                    pr_checked_at: now,
                    pr_url: result.pr_url,
                    last_error: nil
                  },
                  remote_status_attrs(result)
                )
              )
              |> Repo.update!()

              job
              |> Job.changeset(%{
                state: "pr_open",
                result_base_sha: verified.base_sha,
                result_head_sha: verified.head_sha,
                result_diff_digest: verified.diff_digest,
                result_commit_count: verified.commit_count,
                result_verified_at: now,
                last_error: nil
              })
              |> Repo.update!()

              WorktreeAllocation
              |> where(
                [allocation],
                allocation.job_id == ^job.id and allocation.state not in ["cleaning", "removed"]
              )
              |> Repo.update_all(
                set: [
                  state: "waiting",
                  head_sha: verified.head_sha,
                  pr_number: result.pr_number,
                  pr_url: result.pr_url,
                  last_used_at: now,
                  last_error: nil,
                  updated_at: now
                ]
              )

              mark_implementation_agent_waiting(job.id, now)

              insert_audit!(%{
                actor: "repair-agent",
                action: "pr_publication.repair_verified",
                target_type: "pr_publication",
                target_id: publication.id,
                details: %{
                  "previous_head_sha" => publication.remote_head_sha,
                  "head_sha" => verified.head_sha,
                  "base_sha" => verified.base_sha,
                  "diff_digest" => verified.diff_digest,
                  "observed_at" => DateTime.to_iso8601(now)
                }
              })

              load(publication.id)
          end
        end)
      else
        {:error, :invalid_repair_result}
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
    |> preload([:repository, job: [:issue, :repository, :worktree_allocation]])
    |> Repo.get!(id)
  end

  defp managed_pr_numbers(repository_id) do
    PrPublication
    |> join(:inner, [publication], job in Job, on: job.id == publication.job_id)
    |> where(
      [publication, job],
      job.repository_id == ^repository_id and publication.source in ["broker", "agent"] and
        not is_nil(publication.pr_number)
    )
    |> select([publication], publication.pr_number)
    |> Repo.all()
  end

  defp managed_pr_heads(repository) do
    publication_heads =
      PrPublication
      |> join(:inner, [publication], job in Job, on: job.id == publication.job_id)
      |> where(
        [publication, job],
        job.repository_id == ^repository.id and publication.source in ["broker", "agent"] and
          (is_nil(publication.pr_state) or publication.pr_state == "open")
      )
      |> select([publication], publication.branch_name)
      |> Repo.all()

    active_agent_job_heads =
      Job
      |> where(
        [job],
        job.repository_id == ^repository.id and job.publication_source == "agent" and
          job.state in ^@agent_reconciliation_job_states
      )
      |> select([job], job.branch_name)
      |> Repo.all()

    (publication_heads ++ active_agent_job_heads)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new(fn branch ->
      {String.downcase("#{repository.github_owner}/#{repository.github_name}"), branch}
    end)
  end

  defp managed_head?(heads, repository, branch)
       when is_binary(repository) and is_binary(branch),
       do: MapSet.member?(heads, {String.downcase(repository), branch})

  defp managed_head?(_heads, _repository, _branch), do: false

  defp upsert_external_pull!(repository, pull, now) do
    attrs =
      %{
        repository_id: repository.id,
        state: "published",
        idempotency_key: external_key(repository.id, pull.pr_number),
        fencing_token: 0,
        branch_name: pull.head_ref,
        base_sha: pull.base_sha,
        head_sha: pull.head_sha,
        diff_digest: external_version_digest(pull),
        attempt_count: 0,
        pr_number: pull.pr_number,
        pr_url: pull.pr_url,
        remote_head_sha: pull.head_sha,
        remote_base_sha: pull.base_sha,
        published_at: now,
        pr_state: "open",
        pr_checked_at: now,
        source: "external",
        title: pull.title,
        author_login: pull.author_login,
        head_ref: pull.head_ref,
        head_repository: pull.head_repository,
        linked_issue_numbers: %{"numbers" => linked_issue_numbers(pull, repository)},
        last_error: nil
      }
      |> Map.merge(remote_status_attrs(pull))

    case Repo.get_by(PrPublication,
           repository_id: repository.id,
           pr_number: pull.pr_number
         ) do
      nil ->
        %PrPublication{}
        |> PrPublication.changeset(attrs)
        |> Repo.insert!()

      %PrPublication{source: "external"} = publication ->
        attrs =
          attrs
          |> Map.put(:published_at, publication.published_at || now)
          |> preserve_or_reset_health(publication, pull)

        publication |> PrPublication.changeset(attrs) |> Repo.update!()

      %PrPublication{} = managed ->
        managed
    end
  end

  defp preserve_or_reset_health(attrs, publication, pull) do
    cond do
      publication.head_sha == pull.head_sha ->
        attrs
        |> Map.put(:pr_checked_at, publication.pr_checked_at)
        |> Map.put(
          :last_error,
          if(publication.last_error == @external_missing_marker,
            do: nil,
            else: publication.last_error
          )
        )

      Map.has_key?(pull, :mergeability) and Map.has_key?(pull, :checks_state) ->
        attrs

      true ->
        Map.merge(attrs, %{
          pr_checked_at: nil,
          mergeability: "unknown",
          mergeable_state: nil,
          checks_state: "unknown",
          checks_total: 0,
          checks_failed: 0,
          checks_pending: 0
        })
    end
  end

  defp record_external_remote_status!(publication, repository, result, now) do
    if not intended_base?(result, repository) do
      Repo.rollback(:unexpected_pull_request_base)
    end

    attrs =
      %{
        state: "published",
        branch_name: result.head_ref,
        base_sha: result.base_sha,
        head_sha: result.head_sha,
        diff_digest: external_version_digest(result),
        pr_number: result.pr_number,
        pr_url: result.pr_url,
        remote_head_sha: result.head_sha,
        remote_base_sha: result.base_sha,
        pr_state: result.state,
        pr_checked_at: now,
        title: Map.get(result, :title) || publication.title,
        author_login: Map.get(result, :author_login) || publication.author_login,
        head_ref: result.head_ref,
        head_repository: result.head_repository,
        linked_issue_numbers: %{"numbers" => linked_issue_numbers(result, repository)},
        last_error: nil
      }
      |> Map.merge(remote_status_attrs(result))

    publication |> PrPublication.changeset(attrs) |> Repo.update!()
  end

  defp remote_status_projection(publication_id, attempts \\ 2)

  defp remote_status_projection(_publication_id, 0), do: {:error, :concurrent_state_change}

  defp remote_status_projection(publication_id, attempts) do
    revision = Repo.get!(StateRevision, 1).revision
    publication = Repo.get!(PrPublication, publication_id)
    job = publication.job_id && Repo.get!(Job, publication.job_id)
    repository_id = publication.repository_id || job.repository_id

    projection = %{
      revision: revision,
      publication: publication,
      job: job,
      repository: Repo.get!(Repository, repository_id),
      pushing_action_in_flight?: pushing_action_in_flight?(publication.id)
    }

    if Repo.get!(StateRevision, 1).revision == revision do
      {:ok, projection}
    else
      remote_status_projection(publication_id, attempts - 1)
    end
  end

  defp reserve_remote_status_projection!(projection) do
    {reserved, _rows} =
      StateRevision
      |> where(
        [revision],
        revision.id == 1 and revision.revision == ^projection.revision
      )
      |> Repo.update_all(inc: [revision: 1])

    if reserved != 1, do: Repo.rollback(:concurrent_state_change)

    reserve_projected_row!(PrPublication, projection.publication)
    reserve_projected_row!(Repository, projection.repository)
    if projection.job, do: reserve_projected_row!(Job, projection.job)
  end

  defp reserve_projected_row!(schema, projected) do
    {reserved, _rows} =
      schema
      |> where(
        [row],
        row.id == ^projected.id and row.updated_at == ^projected.updated_at
      )
      |> Repo.update_all(set: [updated_at: projected.updated_at])

    if reserved != 1, do: Repo.rollback(:concurrent_state_change)
  end

  defp external_key(repository_id, pr_number) do
    "external:#{repository_id}:#{pr_number}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp external_version_digest(result) do
    "#{result.base_sha}:#{result.head_sha}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp linked_issue_numbers(pull, repository) do
    numbers =
      case Map.get(pull, :linked_issue_numbers) do
        numbers when is_list(numbers) ->
          numbers

        _ ->
          PullRequestClient.linked_issue_numbers(
            Map.get(pull, :body, ""),
            "#{repository.github_owner}/#{repository.github_name}"
          )
      end

    LinkedIssues.sanitize(numbers)
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

  defp valid_gate_evidence?(evidence) do
    evidence[:status] in ["passed", "failed"] and
      is_binary(evidence[:verified_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, evidence.verified_sha) and
      is_binary(evidence[:config_digest]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, evidence.config_digest) and
      is_integer(evidence[:exit_status]) and evidence.exit_status >= 0 and
      is_binary(evidence[:output]) and byte_size(evidence.output) <= 65_536 and
      is_integer(evidence[:duration_ms]) and evidence.duration_ms >= 0
  end

  defp active_publication_claim(publication, fencing_token, attempt_token, now) do
    cond do
      publication.state != "publishing" ->
        {:error, :invalid_publication_state}

      publication.fencing_token != fencing_token ->
        {:error, :stale_fencing_token}

      publication.attempt_token != attempt_token ->
        {:error, :stale_publication_attempt}

      is_nil(publication.attempt_expires_at) ->
        {:error, :publication_claim_expired}

      DateTime.compare(publication.attempt_expires_at, now) != :gt ->
        {:error, :publication_claim_expired}

      true ->
        :ok
    end
  end

  defp valid_remote_status?(result) do
    result[:state] in ["open", "merged", "closed"] and is_binary(result[:pr_url]) and
      github_url?(result.pr_url) and is_binary(result[:head_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.head_sha) and
      is_binary(result[:base_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.base_sha) and
      is_binary(result[:base_ref]) and is_binary(result[:base_repository])
  end

  defp valid_external_status?(result) do
    valid_remote_status?(result) and result.state == "open" and
      is_integer(result[:pr_number]) and result.pr_number > 0 and
      is_binary(result[:title]) and is_binary(result[:head_ref]) and
      is_binary(result[:head_repository]) and
      Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, result.head_repository)
  end

  defp remote_status_attrs(result) do
    result
    |> Map.take([
      :draft,
      :mergeability,
      :mergeable_state,
      :checks_state,
      :comment_count,
      :inline_comment_count,
      :checks_total,
      :checks_failed,
      :checks_pending
    ])
    |> label_attrs(result)
  end

  # The follow-up signal is one label the implementation agent adds to its own
  # pull request. It arrives on every status read, managed or imported.
  defp label_attrs(attrs, %{labels: names}) when is_list(names),
    do: Map.put(attrs, :labels, %{"names" => names})

  defp label_attrs(attrs, _result), do: attrs

  defp valid_agent_result?(result) do
    valid_remote_status?(result) and is_integer(result[:pr_number]) and result.pr_number > 0 and
      is_binary(result[:head_ref]) and is_binary(result[:head_repository])
  end

  defp valid_verified_result?(result) do
    is_binary(result[:base_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.base_sha) and
      is_binary(result[:head_sha]) and
      Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, result.head_sha) and
      is_binary(result[:diff_digest]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, result.diff_digest) and
      is_integer(result[:commit_count]) and result.commit_count > 0
  end

  defp repair_lineage_open?(%{state: "published"}, %{state: "pr_open"}), do: true

  defp repair_lineage_open?(
         %{state: "blocked", last_error: "GitHub reports a different pull-request head commit."},
         %{state: "publish_blocked"}
       ),
       do: true

  defp repair_lineage_open?(_publication, _job), do: false

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

  defp adopt_matching_external_publication!(publication, job, repository, result, now) do
    duplicate =
      Repo.get_by(PrPublication,
        repository_id: repository.id,
        pr_number: result.pr_number
      )

    cond do
      is_nil(duplicate) or duplicate.id == publication.id ->
        publication

      matching_external_identity?(duplicate, result) and action_in_flight?(duplicate.id) ->
        defer_agent_adoption!(publication, duplicate, now)

      matching_external_identity?(duplicate, result) ->
        external_id = duplicate.id
        transfer_external_history!(external_id, publication.id)
        Repo.delete!(duplicate)

        insert_audit!(%{
          actor: "github-reconciler",
          action: "pr_publication.external_adopted",
          target_type: "pr_publication",
          target_id: publication.id,
          details: %{
            "job_id" => job.id,
            "pr_number" => result.pr_number,
            "replaced_external_publication_id" => external_id,
            "observed_at" => DateTime.to_iso8601(now)
          }
        })

        publication
        |> PrPublication.changeset(%{next_attempt_at: nil, last_error: nil})
        |> Repo.update!()

      true ->
        Repo.rollback(:pull_request_identity_conflict)
    end
  end

  defp matching_external_identity?(publication, result) do
    PrPublication.external?(publication) and publication.head_ref == result.head_ref and
      String.downcase(publication.head_repository || "") ==
        String.downcase(result.head_repository)
  end

  defp action_in_flight?(publication_id) do
    AgentAction
    |> where(
      [action],
      action.target_type == "pull_request" and action.target_id == ^publication_id and
        action.state in ^AgentAction.pending_states()
    )
    |> Repo.exists?()
  end

  @pushing_action_keys ~w(repair_pr repair_and_merge_pr)

  # Only an action that may push owns the head the poller sees. An analysis, a
  # retrospective, and the collection merge (which is forbidden to change the
  # branch) never push, so a foreign push during one of them is still fenced.
  defp pushing_action_in_flight?(publication_id) do
    AgentAction
    |> where(
      [action],
      action.target_type == "pull_request" and action.target_id == ^publication_id and
        action.action_key in @pushing_action_keys and
        action.state in ^AgentAction.pending_states()
    )
    |> Repo.exists?()
  end

  defp transfer_external_history!(external_id, managed_id) do
    PrAnalysis
    |> where([analysis], analysis.publication_id == ^external_id)
    |> Repo.update_all(set: [publication_id: managed_id])

    MergeApproval
    |> where([approval], approval.publication_id == ^external_id)
    |> Repo.update_all(set: [publication_id: managed_id])

    AgentAction
    |> where(
      [action],
      action.target_type == "pull_request" and action.target_id == ^external_id
    )
    |> Repo.update_all(set: [target_id: managed_id])

    AuditEvent
    |> where(
      [audit],
      audit.target_type == "pr_publication" and audit.target_id == ^external_id
    )
    |> Repo.update_all(set: [target_id: managed_id])
  end

  defp defer_agent_adoption!(publication, duplicate, now) do
    retry_at =
      DateTime.add(
        now,
        Application.get_env(:ptc_manager, :publication_status_interval_ms, 60_000),
        :millisecond
      )

    deferred =
      publication
      |> PrPublication.changeset(%{
        next_attempt_at: retry_at,
        last_error: @external_adoption_deferred
      })
      |> Repo.update!()

    insert_audit!(%{
      actor: "github-reconciler",
      action: "pr_publication.adoption_deferred",
      target_type: "pr_publication",
      target_id: publication.id,
      details: %{
        "external_publication_id" => duplicate.id,
        "pr_number" => duplicate.pr_number,
        "reason" => @external_adoption_deferred,
        "retry_at" => DateTime.to_iso8601(retry_at),
        "observed_at" => DateTime.to_iso8601(now)
      }
    })

    deferred
  end

  defp block_agent_publication!(publication, job, result, message, now) do
    publication
    |> PrPublication.changeset(%{
      state: "blocked",
      pr_number: result.pr_number,
      pr_url: result.pr_url,
      remote_head_sha: result.head_sha,
      remote_base_sha: result.base_sha,
      pr_state: result.state,
      pr_checked_at: now,
      last_error: message
    })
    |> Repo.update!()

    job |> Job.changeset(%{state: "publish_blocked", last_error: message}) |> Repo.update!()
    mark_worktree_attention(job.id, message, now)

    insert_status_audit!(publication, "pr_publication.agent_mismatch", result, now)
    load(publication.id)
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

  defp requested_retry_delay_ms(:database_busy), do: 1_000

  defp requested_retry_delay_ms({:after, delay_ms, {:github_http_error, _, _, delay_ms}})
       when is_integer(delay_ms) and delay_ms > 0,
       do: delay_ms

  defp requested_retry_delay_ms(_reason), do: nil

  defp insert_audit!(attrs), do: %AuditEvent{} |> AuditEvent.changeset(attrs) |> Repo.insert!()

  defp reconcilable_remote_status?(
         %PrPublication{state: publication_state},
         %Job{state: job_state}
       ) do
    publication_state in ["published", "blocked"] and
      job_state in ["pr_open", "publish_blocked"]
  end

  defp reconcilable_remote_status?(_publication, _job), do: false

  defp mark_implementation_agent_waiting(job_id, now) do
    AgentRun
    |> where(
      [run],
      run.job_id == ^job_id and run.role == "implementer" and
        run.state in ["idle", "done", "waiting"]
    )
    |> Repo.update_all(
      set: [
        state: "waiting",
        status_text: "Retained with its PR context; waiting for CI or maintainer action.",
        last_heartbeat_at: now,
        ended_at: nil,
        updated_at: now
      ]
    )
  end

  defp finish_retained_implementation_agent(job_id, pr_state, now) do
    status_text =
      if pr_state == "merged",
        do: "PR merged; the retained session is ready for cleanup.",
        else: "PR closed; the retained session is ready for cleanup."

    AgentRun
    |> where(
      [run],
      run.job_id == ^job_id and run.role == "implementer" and
        run.state not in ["failed", "lost"]
    )
    |> Repo.update_all(
      set: [
        state: "done",
        status_text: status_text,
        last_heartbeat_at: now,
        ended_at: now,
        updated_at: now
      ]
    )
  end

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
