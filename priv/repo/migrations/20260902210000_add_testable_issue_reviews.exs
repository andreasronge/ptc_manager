defmodule PtcManager.Repo.Migrations.AddTestableIssueReviews do
  use Ecto.Migration

  @marker "system:testable-issue-review"
  @old_prompt "Review whether the issue is genuinely ready to implement. Improve it and update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Do not implement it, and explain the result simply."
  @new_prompt "Review whether the issue is genuinely ready to implement. Use the disposable workspace to run relevant tests and create temporary reproduction tests when useful. Improve the issue and update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Exploratory source changes will be discarded: do not implement the fix, commit, push, or open a pull request. Explain the result simply."

  def up do
    execute("""
    INSERT INTO automation_definition_versions (
      automation_definition_id,
      version,
      target_type,
      execution_profile,
      agent_selector,
      github_access,
      queue_lane,
      resource_class,
      lock_policy,
      timeout_seconds,
      result_type,
      result_protocol_version,
      prompt,
      configuration_snapshot,
      created_by,
      inserted_at
    )
    SELECT
      definition.id,
      (SELECT max(existing.version) + 1
       FROM automation_definition_versions AS existing
       WHERE existing.automation_definition_id = definition.id),
      current.target_type,
      'ephemeral_investigation',
      current.agent_selector,
      current.github_access,
      current.queue_lane,
      'heavy',
      current.lock_policy,
      current.timeout_seconds,
      current.result_type,
      current.result_protocol_version,
      CASE
        WHEN current.created_by = 'system:built-in'
          THEN replace(current.prompt, '#{escape(@old_prompt)}', '#{escape(@new_prompt)}')
        ELSE current.prompt
      END,
      current.configuration_snapshot,
      '#{@marker}',
      strftime('%Y-%m-%dT%H:%M:%f000Z', 'now')
    FROM automation_definitions AS definition
    JOIN automation_definition_versions AS current
      ON current.id = definition.current_version_id
    WHERE definition.key = 'review_issue'
      AND current.execution_profile != 'ephemeral_investigation'
      AND current.created_by = 'system:built-in'
    """)

    execute("""
    UPDATE automation_definitions
    SET current_version_id = (
      SELECT version.id
      FROM automation_definition_versions AS version
      WHERE version.automation_definition_id = automation_definitions.id
        AND version.created_by = '#{@marker}'
      ORDER BY version.version DESC
      LIMIT 1
    )
    WHERE key = 'review_issue'
      AND current_version_id IN (
        SELECT id
        FROM automation_definition_versions
        WHERE created_by = 'system:built-in'
      )
      AND EXISTS (
        SELECT 1
        FROM automation_definition_versions AS version
        WHERE version.automation_definition_id = automation_definitions.id
          AND version.created_by = '#{@marker}'
      )
    """)
  end

  def down do
    execute("""
    UPDATE automation_definitions
    SET current_version_id = (
      SELECT version.id
      FROM automation_definition_versions AS version
      WHERE version.automation_definition_id = automation_definitions.id
        AND version.created_by != '#{@marker}'
      ORDER BY version.version DESC
      LIMIT 1
    )
    WHERE key = 'review_issue'
      AND current_version_id IN (
        SELECT id
        FROM automation_definition_versions
        WHERE created_by = '#{@marker}'
      )
    """)
  end

  defp escape(value), do: String.replace(value, "'", "''")
end
