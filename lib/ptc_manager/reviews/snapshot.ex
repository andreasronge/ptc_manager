defmodule PtcManager.Reviews.Snapshot do
  @moduledoc "Captures bounded Git evidence rather than trusting an implementer's reported SHA."
  def capture(%{worktree_allocation: %{path: path}, repository: repository, issue: issue} = job)
      when is_binary(path) do
    with {:ok, evidence} <- PtcManager.Repository.GitProbe.review_patch(repository, job, path),
         {:ok, requirements} <- PtcManager.Reviews.Requirements.capture(job) do
      {:ok,
       evidence
       |> Map.put(:requirements, requirements)
       |> Map.take([:requirements, :head_sha, :base_sha, :diff_digest, :diff, :diff_on_disk])
       |> Map.new(fn {key, value} -> {to_string(key), value} end)
       |> Map.put(
         "issue_url",
         "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{issue.number}"
       )
       |> Map.put(
         "issue",
         String.slice(
           (job.execution_settings["issue_title"] || issue.title) <>
             "\n" <>
             (job.execution_settings["issue_body"] || issue.body || ""),
           0,
           20_000
         )
       )}
    end
  end

  def capture(_), do: {:error, :review_worktree_missing}
end
