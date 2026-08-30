defmodule PtcManager.Repo.Migrations.ImportExternalPullRequests do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute(fn ->
      PtcManager.Repo.checkout(fn -> rebuild_publications_table() end)
    end)
  end

  def down do
    raise "20260830073000 cannot be reversed safely after importing external pull requests"
  end

  defp rebuild_publications_table do
    query!("PRAGMA foreign_keys = OFF")
    query!("PRAGMA legacy_alter_table = ON")

    try do
      query!("BEGIN IMMEDIATE")

      try do
        query!("ALTER TABLE pr_publications RENAME TO pr_publications_before_external_import")

        query!("""
        CREATE TABLE pr_publications (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          job_id INTEGER CONSTRAINT pr_publications_job_id_fkey REFERENCES jobs(id) ON DELETE CASCADE,
          repository_id INTEGER CONSTRAINT pr_publications_repository_id_fkey REFERENCES repositories(id) ON DELETE CASCADE,
          state TEXT DEFAULT 'queued' NOT NULL,
          idempotency_key TEXT NOT NULL,
          fencing_token INTEGER NOT NULL,
          branch_name TEXT NOT NULL,
          base_sha TEXT NOT NULL,
          head_sha TEXT NOT NULL,
          diff_digest TEXT NOT NULL,
          attempt_count INTEGER DEFAULT 0 NOT NULL,
          attempt_token TEXT,
          attempt_expires_at TEXT,
          next_attempt_at TEXT,
          last_error TEXT,
          pr_number INTEGER,
          pr_url TEXT,
          remote_head_sha TEXT,
          remote_base_sha TEXT,
          published_at TEXT,
          pr_state TEXT,
          pr_checked_at TEXT,
          source TEXT DEFAULT 'broker' NOT NULL,
          title TEXT,
          author_login TEXT,
          head_ref TEXT,
          head_repository TEXT,
          draft INTEGER DEFAULT false NOT NULL,
          mergeability TEXT DEFAULT 'unknown' NOT NULL,
          mergeable_state TEXT,
          checks_state TEXT DEFAULT 'unknown' NOT NULL,
          checks_total INTEGER DEFAULT 0 NOT NULL,
          checks_failed INTEGER DEFAULT 0 NOT NULL,
          checks_pending INTEGER DEFAULT 0 NOT NULL,
          inserted_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
        """)

        query!("""
        INSERT INTO pr_publications (
          id, job_id, repository_id, state, idempotency_key, fencing_token,
          branch_name, base_sha, head_sha, diff_digest, attempt_count, attempt_token,
          attempt_expires_at, next_attempt_at, last_error, pr_number, pr_url,
          remote_head_sha, remote_base_sha, published_at, pr_state, pr_checked_at,
          source, title, author_login, head_ref, head_repository,
          draft, mergeability, mergeable_state, checks_state, checks_total,
          checks_failed, checks_pending, inserted_at, updated_at
        )
        SELECT
          publications.id, publications.job_id, jobs.repository_id, publications.state,
          publications.idempotency_key, publications.fencing_token, publications.branch_name,
          publications.base_sha, publications.head_sha, publications.diff_digest,
          publications.attempt_count, publications.attempt_token, publications.attempt_expires_at,
          publications.next_attempt_at, publications.last_error, publications.pr_number,
          publications.pr_url, publications.remote_head_sha, publications.remote_base_sha,
          publications.published_at, publications.pr_state, publications.pr_checked_at,
          publications.source, issues.title, NULL, publications.branch_name,
          repositories.github_owner || '/' || repositories.github_name,
          publications.draft, publications.mergeability, publications.mergeable_state,
          publications.checks_state, publications.checks_total, publications.checks_failed,
          publications.checks_pending, publications.inserted_at, publications.updated_at
        FROM pr_publications_before_external_import AS publications
        JOIN jobs ON jobs.id = publications.job_id
        JOIN issues ON issues.id = jobs.issue_id
        JOIN repositories ON repositories.id = jobs.repository_id
        """)

        query!("DROP TABLE pr_publications_before_external_import")
        query!("CREATE UNIQUE INDEX pr_publications_job_id_index ON pr_publications (job_id)")

        query!(
          "CREATE UNIQUE INDEX pr_publications_idempotency_key_index ON pr_publications (idempotency_key)"
        )

        query!(
          "CREATE INDEX pr_publications_state_next_attempt_at_index ON pr_publications (state, next_attempt_at)"
        )

        query!(
          "CREATE INDEX pr_publications_pr_state_pr_checked_at_index ON pr_publications (pr_state, pr_checked_at)"
        )

        query!("""
        CREATE UNIQUE INDEX pr_publications_repository_pr_number_index
        ON pr_publications (repository_id, pr_number)
        WHERE repository_id IS NOT NULL AND pr_number IS NOT NULL
        """)

        query!(
          "CREATE INDEX pr_publications_repository_id_source_pr_state_index ON pr_publications (repository_id, source, pr_state)"
        )

        case query!("PRAGMA foreign_key_check").rows do
          [] ->
            query!("COMMIT")

          rows ->
            raise "foreign-key violations after rebuilding pr_publications: #{inspect(rows)}"
        end
      rescue
        error ->
          _ = Ecto.Adapters.SQL.query(PtcManager.Repo, "ROLLBACK", [])
          reraise error, __STACKTRACE__
      end
    after
      query!("PRAGMA legacy_alter_table = OFF")
      query!("PRAGMA foreign_keys = ON")
    end
  end

  defp query!(sql), do: Ecto.Adapters.SQL.query!(PtcManager.Repo, sql, [])
end
