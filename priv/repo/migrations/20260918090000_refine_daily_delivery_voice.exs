defmodule PtcManager.Repo.Migrations.RefineDailyDeliveryVoice do
  use Ecto.Migration

  @old "Write a concise daily update from the supplied delivery evidence. Explain what shipped and why it matters, then include only concrete, attributed lessons when the evidence supports them. Keep unknowns explicit and reported claims attributed. Do not propose or create issues."
  @new "Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues."

  def up, do: replace_prompt(@old, @new)
  def down, do: replace_prompt(@new, @old)

  defp replace_prompt(from, to) do
    execute """
    UPDATE automation_definition_versions
    SET prompt = replace(prompt, '#{from}', '#{to}')
    WHERE created_by = 'system:built-in'
      AND EXISTS (
        SELECT 1 FROM automation_definitions AS definition
        JOIN repositories AS repository ON repository.id = definition.repository_id
        WHERE definition.id = automation_definition_versions.automation_definition_id
          AND definition.key = 'daily_digest'
          AND (prompt = '#{from}' OR
            prompt = 'For ' || repository.github_owner || '/' || repository.github_name || ': #{from}')
      )
    """
  end
end
