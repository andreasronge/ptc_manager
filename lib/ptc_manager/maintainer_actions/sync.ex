defmodule PtcManager.MaintainerActions.Sync do
  @moduledoc "Reconciles the canonical GitHub target after every maintainer-action attempt."

  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Operations.Issue
  alias PtcManager.Repo

  def sync_action(%{target_type: "issue", target_id: issue_id}) do
    issue = Issue |> Repo.get!(issue_id) |> Repo.preload(:repository)
    GitHubSync.sync_issue(issue.repository, issue.number)
  end

  def sync_action(%{target_type: "pull_request", repository: repository}) do
    GitHubSync.sync_repository(repository)
  end
end
