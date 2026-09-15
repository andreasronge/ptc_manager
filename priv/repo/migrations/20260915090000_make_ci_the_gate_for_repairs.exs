defmodule PtcManager.Repo.Migrations.MakeCiTheGateForRepairs do
  use Ecto.Migration

  alias PtcManager.Automations.PromptRewrite

  # A repair resumes a retained implementer whose task policy asks for a passed
  # managed review before it pushes; no review is available inside an action,
  # so the agent committed the repair, refused to push, and stopped. The built-in
  # repair prompts now say that the pull request's CI is the gate.
  #
  # The fix-and-merge prompt is matched in both of its earlier forms: the one
  # `20260912170000_require_default_branch_sync_before_merge` meant to write,
  # and the one before it, because that migration bound its parameters by first
  # appearance and rewrote nothing.
  @repair_from "Fix the pull request's failing CI or merge conflicts, validate and review the repair, then push the existing PR branch. Do not create another PR, merge, or force-push."
  @repair_to "Fix the pull request's failing CI or merge conflicts, validate the repair with the repository's own checks, then push the existing PR branch; the pull request's CI is the gate for a repair, because the managed review is not available in an action. Do not create another PR, merge, or force-push."

  @merge_from_without_sync "Fix the pull request's failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Do not force-push or work on another PR."
  @merge_from_with_sync "Fix the pull request's failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Bring the branch up to date with the latest default branch and revalidate before you merge, so the result is proven against what it merges into. Do not force-push or work on another PR."
  @merge_to "Fix the pull request's failing CI or merge conflicts, validate the repair with the repository's own checks, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable; the pull request's CI is the gate for a repair, because the managed review is not available in an action. Bring the branch up to date with the latest default branch and revalidate before you merge, so the result is proven against what it merges into. Do not force-push or work on another PR."

  def up do
    execute(fn ->
      PromptRewrite.rewrite_built_in(repo(), "repair_pr", @repair_from, @repair_to)

      PromptRewrite.rewrite_built_in(
        repo(),
        "repair_and_merge_pr",
        @merge_from_without_sync,
        @merge_to
      )

      PromptRewrite.rewrite_built_in(
        repo(),
        "repair_and_merge_pr",
        @merge_from_with_sync,
        @merge_to
      )
    end)
  end

  def down do
    execute(fn ->
      PromptRewrite.rewrite_built_in(repo(), "repair_pr", @repair_to, @repair_from)

      PromptRewrite.rewrite_built_in(
        repo(),
        "repair_and_merge_pr",
        @merge_to,
        @merge_from_with_sync
      )
    end)
  end
end
