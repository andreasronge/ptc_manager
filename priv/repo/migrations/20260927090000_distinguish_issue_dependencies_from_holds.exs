defmodule PtcManager.Repo.Migrations.DistinguishIssueDependenciesFromHolds do
  use Ecto.Migration

  @guidance "When another issue is the only obstacle, record a native blocked-by relation and label this issue `ptc:ready` if it is otherwise fully specified. Use `ptc:blocked` only for a hold no issue captures. "

  def up do
    replace_built_in("prepare_issue", "Do not implement it, and explain the result simply.")
    replace_built_in("review_issue", "Exploratory source changes will be discarded:")
  end

  def down do
    for key <- ["prepare_issue", "review_issue"] do
      execute("""
      UPDATE automation_definition_versions
      SET prompt = replace(prompt, '#{@guidance}', '')
      WHERE created_by = 'system:built-in'
        AND automation_definition_id IN (
          SELECT id FROM automation_definitions WHERE key = '#{key}'
        )
      """)
    end
  end

  defp replace_built_in(key, sentence) do
    execute("""
    UPDATE automation_definition_versions
    SET prompt = replace(prompt, '#{sentence}', '#{@guidance}#{sentence}')
    WHERE created_by = 'system:built-in'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions WHERE key = '#{key}'
      )
      AND instr(prompt, '#{@guidance}') = 0
    """)
  end
end
