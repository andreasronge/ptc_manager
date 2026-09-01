defmodule PtcManager.Repo.Migrations.ArchiveMergeDecisionAutomation do
  use Ecto.Migration

  def up do
    execute """
    UPDATE automation_triggers
    SET enabled = 0, updated_at = CURRENT_TIMESTAMP
    WHERE automation_definition_id IN (
      SELECT id FROM automation_definitions WHERE key = 'prepare_merge_decision'
    )
    """

    execute """
    UPDATE automation_definitions
    SET enabled = 0, archived_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
    WHERE key = 'prepare_merge_decision'
    """
  end

  def down do
    execute """
    UPDATE automation_definitions
    SET enabled = 1, archived_at = NULL, updated_at = CURRENT_TIMESTAMP
    WHERE key = 'prepare_merge_decision'
    """
  end
end
