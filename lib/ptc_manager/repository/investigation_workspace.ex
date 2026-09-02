defmodule PtcManager.Repository.InvestigationWorkspace do
  @moduledoc "Derives the bounded identity of one disposable issue-review worktree."

  alias PtcManager.Operations.{AgentAction, Repository}
  alias PtcManager.Repository.Checkout

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def identity(%AgentAction{
        id: id,
        action_key: "review_issue",
        target_type: "issue",
        target_id: issue_id,
        attempt_count: attempt,
        target_snapshot: %{"source_sha" => source_sha}
      })
      when is_integer(id) and is_integer(issue_id) and is_integer(attempt) and
             is_binary(source_sha) do
    if Regex.match?(@sha, source_sha) do
      {:ok,
       %{
         branch: "ptc-manager/review-issue-#{issue_id}-action-#{id}-f#{attempt}",
         source_sha: source_sha
       }}
    else
      {:error, :investigation_source_invalid}
    end
  end

  def identity(%AgentAction{}), do: {:error, :invalid_investigation_action}

  def path(root, %Repository{} = repository, %AgentAction{id: id, attempt_count: attempt})
      when is_binary(root) and is_integer(id) and is_integer(attempt) do
    Path.join(
      Path.expand(root),
      "#{Checkout.slug(repository)}-review-action-#{id}-f#{attempt}"
    )
  end
end
