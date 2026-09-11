defmodule PtcManager.Reviews.Snapshot do
  @moduledoc "Captures bounded Git evidence rather than trusting an implementer's reported SHA."
  def capture(%{worktree_allocation: %{path: path}, repository: repository, issue: issue} = job)
      when is_binary(path) do
    issue_text = issue_text(job, issue)

    with {:ok, requirements} <- PtcManager.Reviews.Requirements.capture(job),
         {:ok, evidence} <-
           PtcManager.Repository.GitProbe.review_patch(
             repository,
             job,
             path,
             PtcManager.Reviews.last_reviewed_head(job, issue_text, requirements)
           ) do
      {:ok,
       evidence
       |> Map.put(:requirements, requirements)
       |> Map.take([
         :requirements,
         :head_sha,
         :base_sha,
         :review_base_sha,
         :diff_digest,
         :diff,
         :diff_on_disk
       ])
       |> Map.new(fn {key, value} -> {to_string(key), value} end)
       |> Map.put(
         "issue_url",
         "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{issue.number}"
       )
       |> Map.put("issue", issue_text)}
    end
  end

  def capture(_), do: {:error, :review_worktree_missing}

  defp issue_text(job, issue) do
    String.slice(
      (job.execution_settings["issue_title"] || issue.title) <>
        "\n" <>
        (job.execution_settings["issue_body"] || issue.body || ""),
      0,
      20_000
    )
  end
end
