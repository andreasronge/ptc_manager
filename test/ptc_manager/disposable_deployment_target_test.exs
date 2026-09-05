defmodule PtcManager.DisposableDeploymentTargetTest do
  use ExUnit.Case, async: false

  @moduletag :nightly

  import PtcManager.OperationsFixtures

  alias PtcManager.DeploymentCanary
  alias PtcManager.DisposableDeploymentTarget
  alias PtcManager.OperationalMode
  alias PtcManager.Operations.{AgentRun, Issue, Proposal, Repository}
  alias PtcManager.Repo

  setup context do
    previous_mode = Application.get_env(:ptc_manager, :operational_mode)
    Application.put_env(:ptc_manager, :operational_mode, :maintenance)

    on_exit(fn ->
      restore_env(:operational_mode, previous_mode)
    end)

    target = DisposableDeploymentTarget.start!(Map.get(context, :migration_opts, []))
    on_exit(fn -> DisposableDeploymentTarget.close!(target) end)

    {:ok, target: target}
  end

  test "a pre-effect failure restores the database snapshot", %{target: target} do
    repository = repository_fixture(%{github_owner: "checkpoint", github_name: "baseline"})
    baseline_issue = issue_fixture(repository, %{number: 101})
    target = DisposableDeploymentTarget.snapshot!(target)

    transient_issue = issue_fixture(repository, %{number: 102})
    assert Repo.get!(Issue, transient_issue.id)

    target = DisposableDeploymentTarget.recover_failure!(target, :swapping_pre_effect)

    assert Repo.get!(Repository, repository.id)
    assert Repo.get!(Issue, baseline_issue.id)
    refute Repo.get(Issue, transient_issue.id)
    assert OperationalMode.mode() == :maintenance

    assert DisposableDeploymentTarget.trace(target) == [
             :target_created,
             :repository_started,
             :migrations_applied,
             :pre_effect_snapshot_taken,
             :repository_stopped,
             :pre_effect_snapshot_restored,
             :repository_started
           ]
  end

  test "ordinary work stays paused until the one canary activates it", %{target: target} do
    repository = repository_fixture(%{github_owner: "checkpoint", github_name: "canary"})
    issue_fixture(repository, %{number: 201})
    worker_fixture(%{worker_key: "checkpoint-worker", status: "online"})

    assert {:error, :maintenance_mode} = OperationalMode.authorize_ordinary_work()

    refute Repo.exists?(Proposal)

    assert {:ok, summary} = DeploymentCanary.run("disposable-release")
    assert OperationalMode.mode() == {:canary, "disposable-release"}
    assert Repo.get!(Proposal, summary.proposal_id)
    assert Repo.get!(AgentRun, summary.run_id).state == "done"

    assert {:error, :maintenance_mode} = OperationalMode.authorize_ordinary_work()

    assert :ok = DeploymentCanary.activate("disposable-release", wake: fn -> :ok end)
    assert OperationalMode.mode() == :active

    assert :ok = OperationalMode.authorize_ordinary_work()

    assert DisposableDeploymentTarget.trace(target) == [
             :target_created,
             :repository_started,
             :migrations_applied
           ]
  end

  test "a post-effect failure preserves the canary result and fails closed", %{target: target} do
    repository = repository_fixture(%{github_owner: "checkpoint", github_name: "forward-repair"})
    issue_fixture(repository, %{number: 301})
    worker_fixture(%{worker_key: "checkpoint-worker", status: "online"})
    target = DisposableDeploymentTarget.snapshot!(target)

    assert {:ok, summary} = DeploymentCanary.run("effectful-release")
    target = DisposableDeploymentTarget.record(target, :canary_result_persisted)

    target = DisposableDeploymentTarget.recover_failure!(target, :post_effect)

    assert Repo.get!(Proposal, summary.proposal_id)
    assert Repo.get!(AgentRun, summary.run_id).state == "done"
    assert OperationalMode.mode() == :maintenance

    assert {:error, :canary_not_admitted} =
             DeploymentCanary.activate("effectful-release", wake: fn -> :ok end)

    trace = DisposableDeploymentTarget.trace(target)
    assert :canary_result_persisted in trace, "deployment trace: #{inspect(trace)}"
    assert :post_effect_database_preserved in trace, "deployment trace: #{inspect(trace)}"
    refute :pre_effect_snapshot_restored in trace, "deployment trace: #{inspect(trace)}"
  end

  @tag migration_opts: [to: 20_260_830_001_000]
  test "the external-PR table rebuild transforms data only on the selected Repo", %{
    target: target
  } do
    default_repo = target.previous_dynamic_repo
    default_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(default_repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(default_owner) end)

    timestamp = "2026-08-31T20:00:00.000000Z"
    default_sentinel_key = "default-repo-sentinel-#{System.unique_integer([:positive])}"

    [[default_sentinel_id]] =
      Ecto.Adapters.SQL.query!(
        default_repo,
        """
        INSERT INTO pr_publications
          (state, idempotency_key, fencing_token, branch_name, base_sha, head_sha,
           diff_digest, source, title, inserted_at, updated_at)
        VALUES ('published', ?, 1, 'external/sentinel', ?, ?, ?, 'external',
                'Default Repo sentinel', ?, ?)
        RETURNING id
        """,
        [
          default_sentinel_key,
          String.duplicate("d", 40),
          String.duplicate("e", 40),
          String.duplicate("f", 64),
          timestamp,
          timestamp
        ]
      ).rows

    default_schema_before = publication_schema(default_repo)
    default_sentinel_before = publication_row(default_repo, default_sentinel_id)

    Repo.query!(
      """
      INSERT INTO repositories
        (id, github_owner, github_name, default_branch, enabled, inserted_at, updated_at)
      VALUES (1, 'fixture-owner', 'fixture-repo', 'main', 1, ?, ?)
      """,
      [timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO issues
        (id, repository_id, number, title, html_url, state, body_digest, content_digest,
         github_updated_at, inserted_at, updated_at)
      VALUES (1, 1, 42, 'Imported issue', 'https://example.test/issues/42', 'open',
              'body-digest', 'content-digest', ?, ?, ?)
      """,
      [timestamp, timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO proposals
        (id, issue_id, source_updated_at, source_digest, proposal_digest, plain_summary,
         why_it_matters, scope, risk, readiness, technical_evidence, inserted_at)
      VALUES (1, 1, ?, 'content-digest', 'proposal-digest', 'Summary', 'Reason',
              'small', 'low', 'ready', 'Evidence', ?)
      """,
      [timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO approvals
        (id, proposal_id, decision, actor, source_updated_at, source_digest,
         proposal_digest, approved_at, inserted_at)
      VALUES (1, 1, 'approve', 'fixture', ?, 'content-digest', 'proposal-digest', ?, ?)
      """,
      [timestamp, timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO jobs
        (id, repository_id, issue_id, approval_id, kind, state, fencing_token,
         branch_name, inserted_at, updated_at)
      VALUES (1, 1, 1, 1, 'implementation', 'pr_open', 7,
              'agent/issue-42', ?, ?)
      """,
      [timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO pr_publications
        (id, job_id, state, idempotency_key, fencing_token, branch_name, base_sha,
         head_sha, diff_digest, source, draft, mergeability, checks_state,
         checks_total, checks_failed, checks_pending, inserted_at, updated_at)
      VALUES (1, 1, 'published', 'fixture-publication', 7, 'agent/issue-42',
              ?, ?, ?, 'broker', 0, 'mergeable', 'success', 1, 0, 0, ?, ?)
      """,
      [
        String.duplicate("a", 40),
        String.duplicate("b", 40),
        String.duplicate("c", 64),
        timestamp,
        timestamp
      ]
    )

    target = DisposableDeploymentTarget.migrate_remaining!(target)

    [row] =
      Repo.query!("""
      SELECT repository_id, title, head_ref, head_repository, linked_issue_numbers
      FROM pr_publications WHERE id = 1
      """).rows

    assert row == [
             1,
             "Imported issue",
             "agent/issue-42",
             "fixture-owner/fixture-repo",
             ~s({"numbers":[]})
           ]

    columns = Repo.query!("PRAGMA table_info(pr_publications)").rows
    indexes = Repo.query!("PRAGMA index_list(pr_publications)").rows
    assert Enum.any?(columns, &(Enum.at(&1, 1) == "repository_id"))
    assert Enum.any?(columns, &(Enum.at(&1, 1) == "head_repository"))

    assert Enum.any?(
             indexes,
             &(Enum.at(&1, 1) == "pr_publications_repository_pr_number_index")
           )

    assert Repo.query!("PRAGMA foreign_key_check").rows == []

    assert publication_schema(default_repo) == default_schema_before
    assert publication_row(default_repo, default_sentinel_id) == default_sentinel_before

    assert :migrations_applied in DisposableDeploymentTarget.trace(target)
  end

  @tag migration_opts: [to: 20_260_901_010_000]
  test "native dependency migration invalidates legacy projections and rolls back exact edges", %{
    target: target
  } do
    timestamp = "2026-09-01T12:00:00.000000Z"

    Repo.query!(
      """
      INSERT INTO repositories
        (id, github_owner, github_name, default_branch, enabled, inserted_at, updated_at)
      VALUES
        (1, 'owner', 'app', 'main', 1, ?, ?),
        (2, 'owner', 'platform', 'main', 1, ?, ?)
      """,
      [timestamp, timestamp, timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO issues
        (id, repository_id, number, title, html_url, state, dependencies_projected,
         body_digest, content_digest, github_updated_at, inserted_at, updated_at)
      VALUES
        (1, 1, 10, 'Dependent', 'https://example.test/issues/10', 'open', 1,
         'body-1', 'content-1', ?, ?, ?),
        (2, 1, 7, 'Legacy blocker', 'https://example.test/issues/7', 'open', 1,
         'body-2', 'content-2', ?, ?, ?)
      """,
      [timestamp, timestamp, timestamp, timestamp, timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO issue_dependencies
        (issue_id, blocking_issue_id, blocking_issue_number, lookup_state, inserted_at)
      VALUES (1, 2, 7, 'resolved', ?)
      """,
      [timestamp]
    )

    target = DisposableDeploymentTarget.migrate_remaining!(target)

    assert Repo.query!("SELECT count(*) FROM issue_dependencies").rows == [[0]]
    assert Repo.query!("SELECT dependencies_projected FROM issues WHERE id = 1").rows == [[0]]

    Repo.query!(
      """
      INSERT INTO issue_dependencies
        (issue_id, blocking_repository_id, blocking_repository_full_name,
         blocking_issue_number, blocking_state, blocking_state_reason, lookup_state,
         inserted_at)
      VALUES
        (1, 1, 'owner/app', 7, 'closed', 'completed', 'resolved', ?),
        (1, 2, 'owner/platform', 7, 'closed', 'completed', 'resolved', ?)
      """,
      [timestamp, timestamp]
    )

    # Roll back every migration applied after the tagged boundary so this
    # specifically exercises the native dependency migration's down path.
    _target = DisposableDeploymentTarget.rollback!(target, to: 20_260_901_010_000)

    assert Repo.query!("SELECT count(*) FROM issue_dependencies").rows == [[0]]
    assert Repo.query!("SELECT dependencies_projected FROM issues WHERE id = 1").rows == [[0]]

    indexes = Repo.query!("PRAGMA index_list(issue_dependencies)").rows

    assert Enum.any?(
             indexes,
             &(Enum.at(&1, 1) == "issue_dependencies_issue_id_blocking_issue_number_index")
           )
  end

  @tag migration_opts: [to: 20_260_902_200_000]
  test "testable review migration preserves maintainer-authored execution boundaries", %{
    target: target
  } do
    timestamp = "2026-09-02T20:30:00.000000Z"

    Repo.query!(
      """
      INSERT INTO repositories
        (id, github_owner, github_name, default_branch, enabled, inserted_at, updated_at)
      VALUES
        (1, 'owner', 'built-in', 'main', 1, ?, ?),
        (2, 'owner', 'customized', 'main', 1, ?, ?)
      """,
      [timestamp, timestamp, timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO automation_definitions
        (id, repository_id, key, name, description, enabled, inserted_at, updated_at)
      VALUES
        (1, 1, 'review_issue', 'Review issue', 'Built-in review', 1, ?, ?),
        (2, 2, 'review_issue', 'Review issue', 'Customized review', 1, ?, ?)
      """,
      [timestamp, timestamp, timestamp, timestamp]
    )

    Repo.query!(
      """
      INSERT INTO automation_definition_versions
        (id, automation_definition_id, version, target_type, execution_profile,
         agent_selector, github_access, queue_lane, resource_class, lock_policy,
         timeout_seconds, result_type, result_protocol_version, prompt,
         configuration_snapshot, created_by, inserted_at)
      VALUES
        (1, 1, 1, 'issue', 'generic_ephemeral', '{}', 'trusted_direct', 'planning',
         'light', '{}', 1800, 'issue_maintenance', 1, 'Built-in prompt', '{}',
         'system:built-in', ?),
        (2, 2, 1, 'issue', 'generic_ephemeral', '{}', 'trusted_direct', 'planning',
         'light', '{}', 1800, 'issue_maintenance', 1, 'Keep this custom prompt', '{}',
         'maintainer', ?)
      """,
      [timestamp, timestamp]
    )

    Repo.query!("UPDATE automation_definitions SET current_version_id = id")
    _target = DisposableDeploymentTarget.migrate_remaining!(target)

    assert Repo.query!("""
           SELECT definition.repository_id, version.execution_profile, version.resource_class,
                  version.prompt, version.created_by
           FROM automation_definitions AS definition
           JOIN automation_definition_versions AS version
             ON version.id = definition.current_version_id
           ORDER BY definition.repository_id
           """).rows == [
             [
               1,
               "ephemeral_investigation",
               "heavy",
               "Built-in prompt",
               "system:testable-issue-review"
             ],
             [2, "generic_ephemeral", "light", "Keep this custom prompt", "maintainer"]
           ]

    _target = DisposableDeploymentTarget.rollback!(target, step: 2)

    Repo.query!("""
    INSERT INTO automation_definition_versions
      (automation_definition_id, version, target_type, execution_profile,
       agent_selector, github_access, queue_lane, resource_class, lock_policy,
       timeout_seconds, result_type, result_protocol_version, prompt,
       configuration_snapshot, created_by, inserted_at)
    SELECT automation_definition_id, max(version) + 1, target_type, 'generic_ephemeral',
           agent_selector, github_access, queue_lane, 'light', lock_policy,
           timeout_seconds, result_type, result_protocol_version, 'Edited after rollback',
           configuration_snapshot, 'maintainer', '#{timestamp}'
    FROM automation_definition_versions
    WHERE automation_definition_id = 1
    """)

    Repo.query!("""
    UPDATE automation_definitions
    SET current_version_id = (
      SELECT id FROM automation_definition_versions
      WHERE automation_definition_id = 1 AND created_by = 'maintainer'
      ORDER BY version DESC LIMIT 1
    )
    WHERE id = 1
    """)

    _target = DisposableDeploymentTarget.migrate_remaining!(target)

    assert [["generic_ephemeral", "light", "Edited after rollback", "maintainer"]] =
             Repo.query!("""
             SELECT version.execution_profile, version.resource_class, version.prompt,
                    version.created_by
             FROM automation_definitions AS definition
             JOIN automation_definition_versions AS version
               ON version.id = definition.current_version_id
             WHERE definition.id = 1
             """).rows
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)

  defp publication_schema(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT type, name, sql
      FROM sqlite_master
      WHERE name = 'pr_publications' OR tbl_name = 'pr_publications'
      ORDER BY type, name
      """,
      []
    ).rows
  end

  defp publication_row(repo, id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      SELECT id, job_id, repository_id, state, idempotency_key, branch_name,
             head_sha, source, title
      FROM pr_publications WHERE id = ?
      """,
      [id]
    ).rows
  end
end
