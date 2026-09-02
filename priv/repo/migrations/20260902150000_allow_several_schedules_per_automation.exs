defmodule PtcManager.Repo.Migrations.AllowSeveralSchedulesPerAutomation do
  use Ecto.Migration

  @columns [:automation_definition_id, :trigger_type, :surface]

  def up do
    drop unique_index(:automation_triggers, @columns)
    create unique_index(:automation_triggers, @columns, where: "trigger_type <> 'schedule'")

    # Until now a definition could hold one schedule, so the schedule on a
    # built-in definition that ships one is that built-in schedule, whatever it
    # has been renamed to. Marking it lets the bootstrap recognise it without
    # relying on the label once several schedules are allowed.
    execute """
    UPDATE automation_triggers
    SET configuration = '{"built_in":true}'
    WHERE trigger_type = 'schedule'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions
        WHERE key IN ('daily_digest', 'nightly_ci_investigation')
      )
    """
  end

  def down do
    execute """
    UPDATE automation_triggers
    SET configuration = '{}'
    WHERE trigger_type = 'schedule' AND configuration = '{"built_in":true}'
    """

    drop unique_index(:automation_triggers, @columns)
    create unique_index(:automation_triggers, @columns)
  end
end
