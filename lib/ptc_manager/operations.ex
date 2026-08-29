defmodule PtcManager.Operations do
  @moduledoc """
  Owns PtcManager's durable issue approvals, jobs, workers, and agent activity.

  GitHub reconciliation and execution adapters will enter through this boundary
  in later slices. Model output is stored as an immutable proposal and never
  performs an external effect directly.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias PtcManager.Repo

  alias PtcManager.Operations.{
    AgentRun,
    Approval,
    AuditEvent,
    Issue,
    Job,
    Proposal,
    Repository,
    Worker
  }

  @active_job_states ~w(queued starting working idle blocked)
  @topic "operations"

  def subscribe, do: Phoenix.PubSub.subscribe(PtcManager.PubSub, @topic)

  def notify_changed(source) do
    Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:operations_changed, source})
  end

  def list_repositories,
    do: Repository |> order_by([repository], asc: repository.id) |> Repo.all()

  def get_repository!(id), do: Repo.get!(Repository, id)

  def get_issue!(id), do: Issue |> preload(:repository) |> Repo.get!(id)

  def create_repository(attrs),
    do: %Repository{} |> Repository.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_issue(attrs),
    do: %Issue{} |> Issue.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_proposal(attrs),
    do: %Proposal{} |> Proposal.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_worker(attrs),
    do: %Worker{} |> Worker.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def create_agent_run(attrs),
    do: %AgentRun{} |> AgentRun.changeset(attrs) |> Repo.insert() |> broadcast_change()

  def dashboard_issues do
    issues =
      Issue
      |> join(:inner, [issue], repository in assoc(issue, :repository))
      |> order_by([issue], desc: issue.github_updated_at)
      |> preload([_issue, repository], repository: repository)
      |> Repo.all()

    issue_ids = Enum.map(issues, & &1.id)
    proposals = latest_proposals(issue_ids)
    jobs = active_jobs(issue_ids)

    Enum.map(issues, fn issue ->
      %{
        issue: issue,
        proposal: Map.get(proposals, issue.id),
        active_job: Map.get(jobs, issue.id)
      }
    end)
  end

  def list_agent_runs do
    AgentRun
    |> order_by([run], asc: run.started_at)
    |> preload([:worker, job: [:issue, :repository]])
    |> Repo.all()
  end

  def approve_issue(issue_id, actor) when is_integer(issue_id) and is_binary(actor) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Multi.new()
    |> Multi.run(:snapshot, fn repo, _changes -> current_approvable_snapshot(repo, issue_id) end)
    |> Multi.insert(:approval, fn %{snapshot: {issue, proposal}} ->
      Approval.changeset(%Approval{}, %{
        proposal_id: proposal.id,
        decision: "start_implementation",
        actor: actor,
        source_updated_at: issue.github_updated_at,
        source_digest: issue.content_digest,
        proposal_digest: proposal.proposal_digest,
        approved_at: now
      })
    end)
    |> Multi.insert(:job, fn %{snapshot: {issue, _proposal}, approval: approval} ->
      Job.changeset(%Job{}, %{
        repository_id: issue.repository_id,
        issue_id: issue.id,
        approval_id: approval.id,
        kind: "implementation",
        state: "queued",
        fencing_token: 0
      })
    end)
    |> Multi.insert(:audit_event, fn %{snapshot: {issue, proposal}, job: job} ->
      AuditEvent.changeset(%AuditEvent{}, %{
        actor: actor,
        action: "issue.approved_for_implementation",
        target_type: "job",
        target_id: job.id,
        details: %{
          "issue_id" => issue.id,
          "issue_number" => issue.number,
          "proposal_id" => proposal.id,
          "proposal_digest" => proposal.proposal_digest,
          "source_digest" => issue.content_digest
        }
      })
    end)
    |> Repo.transaction()
    |> normalize_approval_result()
    |> broadcast_change()
  end

  defp current_approvable_snapshot(repo, issue_id) do
    with %Issue{} = issue <- repo.get(Issue, issue_id),
         %Proposal{} = proposal <- latest_proposal(repo, issue_id),
         :ok <- issue_is_open(issue),
         :ok <- proposal_is_ready(proposal),
         :ok <- proposal_matches_issue(proposal, issue) do
      {:ok, {issue, proposal}}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp issue_is_open(%Issue{state: "open"}), do: :ok
  defp issue_is_open(%Issue{}), do: {:error, :issue_closed}

  defp proposal_is_ready(%Proposal{readiness: "ready"}), do: :ok
  defp proposal_is_ready(%Proposal{}), do: {:error, :proposal_not_ready}

  defp proposal_matches_issue(proposal, issue) do
    if proposal.source_digest == issue.content_digest and
         DateTime.compare(proposal.source_updated_at, issue.github_updated_at) == :eq do
      :ok
    else
      {:error, :stale_proposal}
    end
  end

  defp latest_proposal(repo, issue_id) do
    Proposal
    |> where([proposal], proposal.issue_id == ^issue_id)
    |> order_by([proposal], desc: proposal.inserted_at, desc: proposal.id)
    |> limit(1)
    |> repo.one()
  end

  defp latest_proposals([]), do: %{}

  defp latest_proposals(issue_ids) do
    Proposal
    |> where([proposal], proposal.issue_id in ^issue_ids)
    |> order_by([proposal], desc: proposal.inserted_at, desc: proposal.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn proposal, proposals ->
      Map.put_new(proposals, proposal.issue_id, proposal)
    end)
  end

  defp active_jobs([]), do: %{}

  defp active_jobs(issue_ids) do
    Job
    |> where(
      [job],
      job.issue_id in ^issue_ids and job.state in ^@active_job_states
    )
    |> order_by([job], desc: job.inserted_at)
    |> Repo.all()
    |> Map.new(&{&1.issue_id, &1})
  end

  defp normalize_approval_result({:ok, %{job: job}}), do: {:ok, job}
  defp normalize_approval_result({:error, :snapshot, reason, _changes}), do: {:error, reason}

  defp normalize_approval_result({:error, :job, changeset, _changes}) do
    if changeset.errors[:issue_id] do
      {:error, :already_active}
    else
      {:error, changeset}
    end
  end

  defp normalize_approval_result({:error, _step, reason, _changes}), do: {:error, reason}

  defp broadcast_change({:ok, record} = result) do
    notify_changed(record.__struct__)
    result
  end

  defp broadcast_change(result), do: result
end
