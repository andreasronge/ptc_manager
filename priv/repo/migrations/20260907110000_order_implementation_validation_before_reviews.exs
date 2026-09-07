defmodule PtcManager.Repo.Migrations.OrderImplementationValidationBeforeReviews do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE automation_definition_versions
    SET prompt = replace(prompt,
      'validate the change, perform the configured reviews, commit it, and publish',
      'run all required checks, commit the validated change, perform the configured reviews, and publish the reviewed commit in')
    WHERE created_by = 'system:built-in' AND automation_definition_id IN
      (SELECT id FROM automation_definitions WHERE key = 'implement_issue')
    """)
  end

  def down, do: :ok
end
