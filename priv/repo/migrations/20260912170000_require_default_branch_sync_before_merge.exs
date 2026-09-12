defmodule PtcManager.Repo.Migrations.RequireDefaultBranchSyncBeforeMerge do
  use Ecto.Migration

  @previous "Fix the pull request's failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Do not force-push or work on another PR."

  @current "Fix the pull request's failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Bring the branch up to date with the latest default branch and revalidate before you merge, so the result is proven against what it merges into. Do not force-push or work on another PR."

  # A changed default reaches only new repositories, so the built-in versions
  # already in use are rewritten here. The stored prompt carries a per-repository
  # prefix, so the sentence is replaced inside it rather than over it. An edited
  # prompt is the maintainer's and is left exactly as it is.
  def up, do: replace_prompt(@previous, @current)

  def down, do: replace_prompt(@current, @previous)

  defp replace_prompt(from, to) do
    execute(
      fn ->
        repo().query!(
          """
          UPDATE automation_definition_versions
          SET prompt = replace(prompt, $2, $1)
          WHERE created_by = 'system:built-in'
            AND instr(prompt, $2) > 0
            AND automation_definition_id IN (
              SELECT id FROM automation_definitions WHERE key = 'repair_and_merge_pr'
            )
          """,
          [to, from]
        )
      end,
      fn -> :ok end
    )
  end
end
