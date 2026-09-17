defmodule PtcManager.Repo.Migrations.MoveDailyDeliveryToFileBundles do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE automation_invocations
    SET state = 'cancelled', ended_at = CURRENT_TIMESTAMP,
        last_error = 'Queued inline daily contract was cancelled at the file-bundle cutover.',
        updated_at = CURRENT_TIMESTAMP
    WHERE agent_action_id IN (
      SELECT id FROM agent_actions
      WHERE action_key = 'daily_digest' AND state = 'queued'
        AND prompt NOT LIKE '%github_access="read"%'
    ) AND state = 'queued'
    """)

    execute("""
    UPDATE agent_actions
    SET state = 'cancelled', ended_at = CURRENT_TIMESTAMP,
        attempt_token = NULL, attempt_expires_at = NULL, next_sync_attempt_at = NULL,
        last_error = 'Queued inline daily contract was cancelled at the file-bundle cutover.',
        updated_at = CURRENT_TIMESTAMP
    WHERE action_key = 'daily_digest' AND state = 'queued'
      AND prompt NOT LIKE '%github_access="read"%'
    """)

    execute("""
    UPDATE automation_definition_versions
    SET github_access = 'read',
        prompt = 'Write a concise daily update for a busy maintainer by investigating the supplied immutable delivery bundle, full available execution logs, repository history, and read-only GitHub context. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep captured facts distinct from current supplemental context and reported claims attributed. Do not propose or create issues, write to GitHub, push, implement, or change production.'
    WHERE created_by = 'system:built-in'
      AND prompt = 'Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues.'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions WHERE key = 'daily_digest'
      )
    """)

    execute("""
    UPDATE automation_definition_versions
    SET github_access = 'read',
        prompt = replace(prompt, 'Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues.', 'Write a concise daily update for a busy maintainer by investigating the supplied immutable delivery bundle, full available execution logs, repository history, and read-only GitHub context. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep captured facts distinct from current supplemental context and reported claims attributed. Do not propose or create issues, write to GitHub, push, implement, or change production.')
    WHERE created_by = 'system:built-in'
      AND substr(prompt, -length('Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues.')) = 'Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues.'
      AND automation_definition_id IN (SELECT id FROM automation_definitions WHERE key = 'daily_digest')
    """)
  end

  def down do
    execute("""
    UPDATE automation_definition_versions
    SET prompt = 'Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues.'
    WHERE created_by = 'system:built-in'
      AND prompt = 'Write a concise daily update for a busy maintainer by investigating the supplied immutable delivery bundle, full available execution logs, repository history, and read-only GitHub context. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep captured facts distinct from current supplemental context and reported claims attributed. Do not propose or create issues, write to GitHub, push, implement, or change production.'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions WHERE key = 'daily_digest'
      )
    """)

    execute("""
    UPDATE automation_definition_versions
    SET prompt = replace(prompt, 'Write a concise daily update for a busy maintainer by investigating the supplied immutable delivery bundle, full available execution logs, repository history, and read-only GitHub context. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep captured facts distinct from current supplemental context and reported claims attributed. Do not propose or create issues, write to GitHub, push, implement, or change production.', 'Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues.')
    WHERE created_by = 'system:built-in'
      AND substr(prompt, -length('Write a concise daily update for a busy maintainer by investigating the supplied immutable delivery bundle, full available execution logs, repository history, and read-only GitHub context. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep captured facts distinct from current supplemental context and reported claims attributed. Do not propose or create issues, write to GitHub, push, implement, or change production.')) = 'Write a concise daily update for a busy maintainer by investigating the supplied immutable delivery bundle, full available execution logs, repository history, and read-only GitHub context. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep captured facts distinct from current supplemental context and reported claims attributed. Do not propose or create issues, write to GitHub, push, implement, or change production.'
      AND automation_definition_id IN (SELECT id FROM automation_definitions WHERE key = 'daily_digest')
    """)
  end
end
