defmodule PtcManager.Repo.Migrations.SimplifyAutomationPrompts do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE automation_definition_versions
    SET prompt = CASE
      WHEN created_by = 'system:built-in' THEN
        'For ' ||
        (SELECT repositories.github_owner || '/' || repositories.github_name
         FROM automation_definitions
         JOIN repositories ON repositories.id = automation_definitions.repository_id
         WHERE automation_definitions.id = automation_definition_versions.automation_definition_id) ||
        ': ' ||
        CASE
          (SELECT key FROM automation_definitions
           WHERE automation_definitions.id = automation_definition_versions.automation_definition_id)
          WHEN 'private_issue_analysis' THEN 'Explain this issue in simple language for the maintainer. Inspect the repository read-only and report readiness, scope, risk, and concrete technical evidence.'
          WHEN 'implement_issue' THEN 'Fix the issue completely. Follow the repository instructions, validate the change, perform the configured reviews, commit it, and publish a pull request that closes the issue and includes a short retrospective. Do not merge it.'
          WHEN 'prepare_issue' THEN 'Prepare the issue for implementation. Re-read the issue and relevant code, then update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Do not implement it, and explain the result simply.'
          WHEN 'review_issue' THEN 'Review whether the issue is genuinely ready to implement. Improve it and update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Do not implement it, and explain the result simply.'
          WHEN 'resolve_issue_decision' THEN 'Apply the maintainer''s decision to the issue, rewrite it so the decision is clear, and leave it ready, blocked, still needing a decision, or closed as appropriate. Do not implement it.'
          WHEN 'daily_digest' THEN 'Write a concise, easy-to-read daily update from the supplied change manifest. Explain what was added, fixed, changed, or removed and include practical examples when the evidence supports them.'
          WHEN 'prepare_merge_decision' THEN 'Review the pull request read-only and prepare a simple merge decision: merge-ready, merge-blocked, or merge-needs-decision. Explain the important evidence without modifying GitHub.'
          WHEN 'repair_pr' THEN 'Fix the pull request''s failing CI or merge conflicts, validate and review the repair, then push the existing PR branch. Do not create another PR, merge, or force-push.'
          WHEN 'repair_and_merge_pr' THEN 'Fix the pull request''s failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Do not force-push or work on another PR.'
          WHEN 'pr_retrospective' THEN 'Review the completed pull request read-only and propose only concrete, untracked follow-up work such as potential bugs, refactoring, flaky tests, or missing tests. Returning no suggestions is valid.'
          WHEN 'create_retrospective_issue' THEN 'Create at most one GitHub issue for the maintainer-approved retrospective suggestion, unless the work is already tracked. Do not modify code or unrelated GitHub items.'
          WHEN 'nightly_ci_investigation' THEN 'Inspect the latest completed nightly GitHub Actions workflow. If it failed, investigate it and create or update one deduplicated issue using the supplied invocation marker; otherwise report that no action was needed.'
          ELSE prompt
        END
      WHEN trim(operational_policy) = '' THEN prompt
      WHEN prompt = 'Use the code-owned target prompt builder for this compatibility definition.' THEN operational_policy
      ELSE operational_policy || char(10) || char(10) || prompt
    END
    """)

    alter table(:automation_definition_versions) do
      remove :operational_policy
    end

    drop table(:prompt_customizations)
  end

  def down do
    create table(:prompt_customizations) do
      add :action_key, :string, null: false
      add :instructions, :text, null: false
      add :updated_by, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:prompt_customizations, [:action_key])

    alter table(:automation_definition_versions) do
      add :operational_policy, :text, null: false, default: ""
    end
  end
end
