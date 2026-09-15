defmodule PtcManager.Repo.Migrations.AddWorktreePreservation do
  use Ecto.Migration

  def change do
    alter table(:worktree_allocations) do
      add :preserved_artifact_path, :string
      add :preserved_bundle_sha256, :string
      add :preserved_patch_sha256, :string
      add :preserved_head_sha, :string
      add :preserved_tree_sha, :string
      add :preserved_at, :utc_datetime_usec
      add :cleanup_purpose, :string
      add :retained_dirty, :boolean
      add :retained_local_commits, :integer
      add :retained_unpushed_commits, :integer
      add :retained_observed_at, :utc_datetime_usec
    end
  end
end
