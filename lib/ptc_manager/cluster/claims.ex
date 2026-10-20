defmodule PtcManager.Cluster.Claims do
  @moduledoc """
  Which member owns a repository, derived from each member's own records.

  A member claims a repository (`owner/name`, lowercased) while any of these
  holds locally: the row is enabled; a job is not terminal; an agent action is
  pending; a collection run is live; a worktree allocation is not released; or
  an unexpired claim intent exists. Nothing stores an owner, so nothing can
  drift from the records that make the claim.

  Acquiring a claim (`acquire/4`) announces an intent, asks every other member
  outside any transaction, and enables the row in one transaction only if no
  member claims the repository, has a pending intent for it, is unreachable,
  is incompatible, or reports another membership revision. Two members
  claiming at once both announce before they read, so at least one refuses.
  No claim is ever taken over automatically.
  """

  import Ecto.Query

  alias PtcManager.{Cluster, Repo, RepoTransaction}
  alias PtcManager.Cluster.{ClaimIntent, Peer}
  alias PtcManager.Collections.Run
  alias PtcManager.Operations.{AgentAction, AuditEvent, Job, Repository, WorktreeAllocation}

  @intent_ms 300_000
  @commit_within_ms 150_000

  def key(%Repository{github_owner: owner, github_name: name}),
    do: String.downcase("#{owner}/#{name}")

  def key(owner, name), do: String.downcase("#{owner}/#{name}")

  @doc """
  Claim states and the conditions behind them for `repositories`, plus every
  unexpired intent. Callers that serve peers run this inside one read
  transaction so all predicates come from one snapshot.
  """
  def snapshot(repositories, now \\ DateTime.utc_now()) do
    ids = Enum.map(repositories, & &1.id)
    jobs = count_by_repository(from(job in Job, where: job.state in ^Job.live_states()), ids)

    actions =
      count_by_repository(
        from(action in AgentAction, where: action.state in ^AgentAction.pending_states()),
        ids
      )

    runs = count_by_repository(from(run in Run, where: run.state in ^Run.live_states()), ids)

    worktrees =
      Repo.all(
        from allocation in WorktreeAllocation,
          join: job in Job,
          on: job.id == allocation.job_id,
          where: job.repository_id in ^ids and allocation.state != "removed",
          group_by: job.repository_id,
          select: {job.repository_id, count(allocation.id)}
      )
      |> Map.new()

    intents =
      Repo.all(from intent in ClaimIntent, where: intent.expires_at > ^now, order_by: intent.id)

    intent_keys = MapSet.new(intents, & &1.repository_key)

    entries =
      for repository <- repositories do
        key = key(repository)

        blockers =
          [
            repository.enabled && "enabled",
            count_words(jobs[repository.id], "unfinished job"),
            count_words(actions[repository.id], "pending agent action"),
            count_words(runs[repository.id], "live collection run"),
            count_words(worktrees[repository.id], "unreleased worktree"),
            MapSet.member?(intent_keys, key) && "claim in progress"
          ]
          |> Enum.filter(& &1)

        state =
          cond do
            repository.enabled -> "enabled"
            blockers -- ["claim in progress"] != [] -> "live_work"
            blockers != [] -> "pending"
            true -> "none"
          end

        {key, state, blockers}
      end
      # Rows that differ only in case are one repository: the strongest claim
      # among them wins and their conditions add up.
      |> Enum.group_by(fn {key, _state, _blockers} -> key end)
      |> Enum.map(fn {key, rows} ->
        {key, rows |> Enum.map(&elem(&1, 1)) |> Enum.max_by(&claim_rank/1),
         rows |> Enum.flat_map(&elem(&1, 2)) |> Enum.uniq()}
      end)

    %{
      states: Map.new(entries, fn {key, state, _blockers} -> {key, state} end),
      blockers: Map.new(entries, fn {key, _state, blockers} -> {key, blockers} end),
      intents:
        Enum.map(intents, fn intent ->
          %{
            "repository" => intent.repository_key,
            "expires_at" => DateTime.to_iso8601(intent.expires_at)
          }
        end)
    }
  end

  defp claim_rank("enabled"), do: 3
  defp claim_rank("live_work"), do: 2
  defp claim_rank("pending"), do: 1
  defp claim_rank("none"), do: 0

  defp count_by_repository(query, ids) do
    query
    |> where([record], record.repository_id in ^ids)
    |> group_by([record], record.repository_id)
    |> select([record], {record.repository_id, count(record.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp count_words(nil, _noun), do: nil
  defp count_words(0, _noun), do: nil
  defp count_words(1, noun), do: "1 #{noun}"
  defp count_words(count, noun), do: "#{count} #{noun}s"

  @doc "This member's claim state and its conditions for one repository."
  def local(%Repository{} = repository) do
    %{states: states, blockers: blockers} = snapshot([repository])
    key = key(repository)
    %{state: states[key], blockers: blockers[key]}
  end

  @doc "Whether this member claims the repository."
  def claimed?(%Repository{} = repository), do: local(repository).state != "none"

  @doc """
  Claims a disabled repository for this member and enables it.

  `apply` runs inside the final transaction with the repository (before it is
  enabled) and the peer checks; a move uses it to import settings, and its
  `{:error, reason}` rolls the claim back. Returns `{:ok, repository, checks}` or
  `{:error, reason, checks}`, where `checks` records each peer's answer.
  """
  def acquire(repository_id, actor, apply \\ fn _repository, _checks -> :ok end, opts \\ [])
      when is_integer(repository_id) and is_binary(actor) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    with {:ok, repository} <- announce(repository_id, actor, token) do
      checks = check_peers(key(repository), opts)

      case Enum.reject(checks, &(&1["result"] == "clear")) do
        [] ->
          case commit(repository_id, token, actor, apply, checks) do
            {:ok, repository} -> {:ok, repository, checks}
            {:error, reason} -> withdraw(token, reason, checks)
          end

        _refusals ->
          withdraw(token, :claim_refused, checks)
      end
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp announce(repository_id, actor, token) do
    now = utc_now()

    RepoTransaction.immediate(fn ->
      repository = Repo.get(Repository, repository_id) || Repo.rollback(:repository_not_found)
      if repository.enabled, do: Repo.rollback(:already_enabled)
      key = key(repository)

      Repo.delete_all(
        from intent in ClaimIntent,
          where: intent.repository_key == ^key and intent.expires_at <= ^now
      )

      %ClaimIntent{}
      |> ClaimIntent.changeset(%{
        repository_key: key,
        token: token,
        actor: actor,
        expires_at: DateTime.add(now, @intent_ms, :millisecond)
      })
      |> Repo.insert()
      |> case do
        {:ok, _intent} -> repository
        {:error, _changeset} -> Repo.rollback(:claim_in_progress)
      end
    end)
  end

  defp withdraw(token, reason, checks) do
    RepoTransaction.immediate(fn ->
      Repo.delete_all(from intent in ClaimIntent, where: intent.token == ^token)
    end)

    {:error, reason, checks}
  end

  defp commit(repository_id, token, actor, apply, checks) do
    now = utc_now()

    RepoTransaction.immediate(fn ->
      intent =
        Repo.one(from intent in ClaimIntent, where: intent.token == ^token) ||
          Repo.rollback(:claim_intent_lost)

      if DateTime.diff(now, intent.inserted_at, :millisecond) >= @commit_within_ms,
        do: Repo.rollback(:claim_intent_expired)

      repository = Repo.get!(Repository, repository_id)
      if repository.enabled, do: Repo.rollback(:already_enabled)

      case apply.(repository, checks) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      updated =
        Repository
        |> Repo.get!(repository_id)
        |> Repository.changeset(%{enabled: true})
        |> Repo.update!()

      Repo.delete!(intent)

      %AuditEvent{}
      |> AuditEvent.changeset(%{
        actor: actor,
        action: "repository.enabled",
        target_type: "repository",
        target_id: repository_id,
        details: %{
          "repository" => "#{repository.github_owner}/#{repository.github_name}",
          "machine_id" => PtcManager.Machine.id(),
          "membership_revision" => Cluster.membership_revision(),
          "peer_checks" => checks
        }
      })
      |> Repo.insert!()

      updated
    end)
  end

  @doc """
  Asks every other member, fresh, whether `key` is free: one check per peer
  with `result` `clear`, `claimed`, `pending`, `unreachable`, `incompatible`,
  `revision_mismatch`, or `not_member`.
  """
  def check_peers(key, opts \\ []) do
    Cluster.peers()
    |> Task.async_stream(
      fn {id, _url} -> check_peer(id, key, opts) end,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, check} -> check end)
  end

  defp check_peer(id, key, opts) do
    result =
      case Peer.fetch_status(id, opts) do
        {:ok, status} -> judge(status, key)
        {:error, :not_a_member} -> {"not_member", nil}
        {:error, reason} -> {"unreachable", inspect(reason)}
      end

    {outcome, detail} = result
    %{"machine_id" => id, "result" => outcome, "detail" => detail}
  end

  defp judge(status, key) do
    repository = Enum.find(List.wrap(status["repositories"]), &(&1["repository"] == key))
    pending? = Enum.any?(List.wrap(status["intents"]), &(&1["repository"] == key))

    cond do
      status["protocol_version"] != Cluster.protocol_version() ->
        {"incompatible", "protocol #{inspect(status["protocol_version"])}"}

      status["membership_revision"] != Cluster.membership_revision() ->
        {"revision_mismatch", status["membership_revision"]}

      repository && repository["claim"] not in [nil, "none"] ->
        {"claimed", repository["claim"]}

      pending? ->
        {"pending", nil}

      true ->
        {"clear", nil}
    end
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
