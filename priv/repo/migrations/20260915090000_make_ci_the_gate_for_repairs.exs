defmodule PtcManager.Repo.Migrations.MakeCiTheGateForRepairs do
  use Ecto.Migration

  # A repair resumes a retained implementer whose task policy asks for a passed
  # managed review before it pushes; no review is available inside an action,
  # so the agent committed the repair, refused to push, and stopped. The built-in
  # repair prompts now say that the pull request's CI is the gate. A changed
  # default reaches only new repositories, so the built-in versions already in
  # use are rewritten here; an edited prompt is the maintainer's and is left.
  @replacements [
    {"repair_pr",
     "Fix the pull request's failing CI or merge conflicts, validate and review the repair, then push the existing PR branch. Do not create another PR, merge, or force-push.",
     "Fix the pull request's failing CI or merge conflicts, validate the repair with the repository's own checks, then push the existing PR branch; the pull request's CI is the gate for a repair, because the managed review is not available in an action. Do not create another PR, merge, or force-push."},
    {"repair_and_merge_pr",
     "Fix the pull request's failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Bring the branch up to date with the latest default branch and revalidate before you merge, so the result is proven against what it merges into. Do not force-push or work on another PR.",
     "Fix the pull request's failing CI or merge conflicts, validate the repair with the repository's own checks, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable; the pull request's CI is the gate for a repair, because the managed review is not available in an action. Bring the branch up to date with the latest default branch and revalidate before you merge, so the result is proven against what it merges into. Do not force-push or work on another PR."}
  ]

  def up, do: Enum.each(@replacements, fn {key, from, to} -> replace_prompt(key, from, to) end)

  def down, do: Enum.each(@replacements, fn {key, from, to} -> replace_prompt(key, to, from) end)

  defp replace_prompt(key, from, to) do
    execute(
      fn ->
        repo().query!(
          """
          UPDATE automation_definition_versions
          SET prompt = replace(prompt, $2, $1)
          WHERE created_by = 'system:built-in'
            AND instr(prompt, $2) > 0
            AND automation_definition_id IN (
              SELECT id FROM automation_definitions WHERE key = $3
            )
          """,
          [to, from, key]
        )
      end,
      fn -> :ok end
    )
  end
end
