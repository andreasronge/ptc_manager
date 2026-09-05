defmodule PtcManager.Repo.Migrations.AddFollowUpLabelToImplementationPrompt do
  use Ecto.Migration

  @moduledoc """
  Teaches existing repositories the follow-up signal.

  Only `system:built-in` versions are rewritten, so a maintainer-authored prompt
  is left exactly as written.
  """

  @old "that you had to guess at. Do not merge it."
  @new "that you had to guess at. If the Retrospective lists untracked follow-up work, add the label `ptc:follow-up` to the pull request. Do not merge it."

  def up, do: replace_built_in("implement_issue", @old, @new)
  def down, do: replace_built_in("implement_issue", @new, @old)

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
