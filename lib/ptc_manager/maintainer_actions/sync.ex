defmodule PtcManager.MaintainerActions.Sync do
  @moduledoc "Reconciles the canonical GitHub target after every maintainer-action attempt."

  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Operations.{Issue, PrPublication}
  alias PtcManager.Publications
  alias PtcManager.Repo

  def sync_action(%{target_type: "issue", target_id: issue_id}) do
    issue = Issue |> Repo.get!(issue_id) |> Repo.preload(:repository)
    GitHubSync.sync_issue(issue.repository, issue.number)
  end

  def sync_action(%{action_key: "prepare_merge_decision", target_id: publication_id}) do
    publication =
      PrPublication
      |> Repo.get!(publication_id)
      |> Repo.preload(job: [:issue, :repository])

    client = Application.fetch_env!(:ptc_manager, :pull_request_client)

    case client.status(publication) do
      {:ok, result} ->
        case Publications.record_remote_status(publication.id, result) do
          {:ok, %{state: "published", pr_state: "open"}} when result.draft == false ->
            {:ok, %{pull_request: result}}

          {:ok, _publication} when result.draft == true ->
            {:terminal_error, :pull_request_is_draft}

          {:ok, _publication} ->
            {:terminal_error, :pull_request_not_open}

          {:error, :publication_not_open} ->
            {:terminal_error, :pull_request_not_open}

          {:error, reason} ->
            {:error, reason}
        end

      {:retry, reason} ->
        {:error, reason}

      {:blocked, reason} ->
        {:terminal_error, reason}

      other ->
        {:error, {:unexpected_status_result, other}}
    end
  end

  def sync_action(%{action_key: "pr_retrospective", repository: repository}) do
    GitHubSync.sync_repository(repository)
  end
end
