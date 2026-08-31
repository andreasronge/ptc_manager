defmodule PtcManager.Repository.CheckoutMigrationAudit do
  @moduledoc false

  def ensure_no_duplicate_local_paths!(repo) do
    result =
      repo.query!("""
      SELECT COUNT(*)
      FROM (
        SELECT local_path
        FROM repositories
        WHERE local_path IS NOT NULL
        GROUP BY local_path
        HAVING COUNT(*) > 1
      ) duplicate_paths
      """)

    case result.rows do
      [[0]] ->
        :ok

      [[count]] when is_integer(count) and count > 0 ->
        raise """
        cannot enforce repository checkout isolation: #{count} duplicate local_path value(s) exist.
        Assign every repository its own checkout path, then retry the migration.
        """

      _unexpected ->
        raise "could not audit repository checkout paths before migration"
    end
  end
end
