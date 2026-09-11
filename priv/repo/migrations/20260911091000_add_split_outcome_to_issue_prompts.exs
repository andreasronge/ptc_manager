defmodule PtcManager.Repo.Migrations.AddSplitOutcomeToIssuePrompts do
  use Ecto.Migration

  @moduledoc """
  Teaches existing repositories that a too-large issue becomes a collection.

  Only `system:built-in` versions are rewritten, so a maintainer-authored prompt
  is left exactly as written. New automations reach existing repositories
  through the bootstrap, which inserts a missing definition on start.
  """

  @split "rejected by closing it, or split (`split`) when it cannot be delivered as one reviewable pull request: more than one independently reviewable deliverable, more than one subsystem, or a change too large for one review pass. Splitting means turning the plan into GitHub sub-issues with native blocked-by ordering as described in the runtime context, never marking the parent ready."

  @prepare_old "needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Do not implement it, and explain the result simply."
  @prepare_new "needs a maintainer decision (`ptc:needs-decision`), #{@split} Do not implement it, and explain the result simply."

  @review_old "needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Exploratory source changes will be discarded"
  @review_new "needs a maintainer decision (`ptc:needs-decision`), #{@split} Exploratory source changes will be discarded"

  def up do
    replace_built_in("prepare_issue", @prepare_old, @prepare_new)
    replace_built_in("review_issue", @review_old, @review_new)
  end

  def down do
    replace_built_in("prepare_issue", @prepare_new, @prepare_old)
    replace_built_in("review_issue", @review_new, @review_old)
  end

  defp replace_built_in(key, old, new) do
    for text <- [key, old, new], String.contains?(text, "'") do
      raise ArgumentError, "prompt phrases must not contain single quotes"
    end

    execute("""
    UPDATE automation_definition_versions
    SET prompt = replace(prompt, '#{old}', '#{new}')
    WHERE created_by = 'system:built-in'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions WHERE key = '#{key}'
      )
    """)
  end
end
