defmodule PtcManager.AutoImplementation do
  @moduledoc "Deterministic, opt-in admission of ready issues to the existing implementation queue."
  import Ecto.Query
  require Logger

  alias PtcManager.{Operations, Repo, RepoTransaction}
  alias PtcManager.Operations.{AgentAction, Approval, Issue, Job, PrPublication, Repository}

  @daily_limit 5

  def configure(repository_id, enabled, actor) when is_boolean(enabled) do
    result =
      RepoTransaction.immediate(fn ->
        repository = Repo.get(Repository, repository_id) || Repo.rollback(:repository_not_found)

        updated =
          repository |> Repository.changeset(%{auto_fix_issues: enabled}) |> Repo.update!()

        PtcManager.ExecutionProfiles.audit(
          actor,
          "repository.auto_fix_updated",
          repository_id,
          %{enabled: enabled, daily_limit: @daily_limit},
          "repository"
        )

        updated
      end)

    Operations.notify_changed(Operations)
    if enabled and match?({:ok, _}, result), do: PtcManager.GitHub.Poller.wake()
    result
  end

  # Called only after a successful GitHub read. A single-issue refresh must not
  # admit other issues from an older repository snapshot.
  def reconcile(repository_id, number \\ nil) do
    case Repo.get(Repository, repository_id) do
      %Repository{enabled: true, auto_fix_issues: true} = repository ->
        query =
          from issue in Issue,
            where:
              issue.repository_id == ^repository_id and issue.state == "open" and
                issue.workflow_label == "ptc:ready" and not issue.workflow_label_conflict and
                issue.structure_projected and
                fragment("json_extract(?, '$.total') = 0", issue.sub_issues),
            order_by: [asc: issue.number]

        query = if number, do: where(query, [issue], issue.number == ^number), else: query
        client = Application.fetch_env!(:ptc_manager, :pull_request_client)

        with {:ok, pulls} <- PtcManager.Gateway.call(client, :list_open, [repository]),
             {:ok, _summary} <-
               PtcManager.Publications.sync_external_open_pull_requests(repository, pulls) do
          query |> Repo.all() |> Enum.map(&Operations.auto_approve_issue(&1.id))
        else
          error ->
            Logger.warning(
              "Automatic implementation skipped: pull request synchronization unavailable for repository #{repository.id}"
            )

            [{:error, {:pull_requests_unavailable, error}}]
        end

      _ ->
        []
    end
  end

  # Runs inside the approval's immediate transaction, serializing checks with
  # job creation and policy updates. Pending issue actions must finish storing
  # their analysis before admission freezes a profile, including postflight recovery.
  # Any previous job consumes automatic eligibility,
  # including failed/cancelled/manual jobs; label toggles never reset it.
  def eligible(repo, issue) do
    repository = repo.get!(Repository, issue.repository_id)

    cond do
      not repository.enabled or not repository.auto_fix_issues ->
        {:error, :auto_fix_disabled}

      issue.workflow_label != "ptc:ready" ->
        {:error, :issue_workflow_not_ready}

      repo.exists?(
        from action in AgentAction,
          where:
            action.repository_id == ^issue.repository_id and action.target_type == "issue" and
              action.target_id == ^issue.id and
                action.state in ["queued", "running", "sync_pending"]
      ) ->
        {:error, :issue_action_active}

      repo.exists?(from job in Job, where: job.issue_id == ^issue.id) ->
        {:error, :already_attempted}

      linked_publication?(repo, issue) ->
        {:error, :issue_has_pull_request}

      daily_count(repo, repository.id) >= @daily_limit ->
        {:error, :auto_fix_daily_limit}

      true ->
        :ok
    end
  end

  def dispatch_allowed(%{approval: %{decision: "start_implementation_automatic"}} = job, remote) do
    cond do
      not job.repository.enabled or not job.repository.auto_fix_issues ->
        {:error, :auto_fix_disabled}

      remote.workflow_label != "ptc:ready" or remote.workflow_label_conflict ->
        {:error, :issue_workflow_not_ready}

      not remote.structure_projected ->
        {:error, :issue_structure_unknown}

      remote.sub_issues["total"] > 0 ->
        {:error, :issue_is_collection}

      Issue.claimed_by_other?(remote, job.repository) ->
        {:error, :issue_claimed}

      linked_publication?(Repo, job.issue) ->
        {:error, :issue_has_pull_request}

      true ->
        :ok
    end
  end

  def dispatch_allowed(%{approval: %{decision: "start_implementation_collection"}} = job, remote),
    do: PtcManager.Collections.dispatch_allowed(job, remote)

  def dispatch_allowed(_job, _remote), do: :ok

  @doc false
  def linked_publication?(repo, issue) do
    from(publication in PrPublication,
      where: publication.repository_id == ^issue.repository_id,
      select: publication.linked_issue_numbers
    )
    |> repo.all()
    |> Enum.any?(fn links -> issue.number in Map.get(links, "numbers", []) end)
  end

  defp daily_count(repo, repository_id) do
    midnight = DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")

    from(job in Job,
      join: approval in Approval,
      on: approval.id == job.approval_id,
      where:
        job.repository_id == ^repository_id and
          approval.decision == "start_implementation_automatic" and
          approval.approved_at >= ^midnight
    )
    |> repo.aggregate(:count)
  end
end
