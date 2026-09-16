defmodule PtcManager.Repo.Migrations.UpdateDailyDeliveryPrompt do
  use Ecto.Migration

  @old "Write a concise, easy-to-read daily update from the supplied change manifest. Explain what was added, fixed, changed, or removed and include practical examples when the evidence supports them."
  @new "Write a concise daily update from the supplied delivery evidence. Explain what shipped and why it matters, then include only concrete, attributed lessons when the evidence supports them. Keep unknowns explicit and reported claims attributed. Do not propose or create issues."

  def up, do: replace_prompt(@old, @new)
  def down, do: replace_prompt(@new, @old)

  defp replace_prompt(from, to) do
    execute """
    UPDATE automation_definition_versions
    SET prompt = replace(prompt, '#{from}', '#{to}')
    WHERE created_by = 'system:built-in'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions WHERE key = 'daily_digest'
      )
    """
  end
end
