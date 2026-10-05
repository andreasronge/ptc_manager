defmodule PtcManager.Repo.Migrations.AddIntegrationBranches do
  use Ecto.Migration

  # Every job and pull request so far targeted its repository's default branch,
  # so that is what each one stores; nothing is retargeted.
  def up do
    alter table(:repositories) do
      add :integration_branches, :map, default: %{"mappings" => []}
      add :github_branch_names, :map, default: %{"names" => []}
      add :github_branches_checked_at, :utc_datetime_usec
    end

    alter table(:approvals) do
      add :base_branch, :string
      add :base_override, :boolean, null: false, default: false
    end

    alter table(:jobs) do
      add :base_branch, :string
    end

    alter table(:pr_publications) do
      add :base_branch, :string
    end

    alter table(:collection_runs) do
      add :base_branch, :string
      add :base_override, :boolean, null: false, default: false
    end

    flush()

    execute("""
    UPDATE jobs
    SET base_branch = (SELECT default_branch FROM repositories WHERE repositories.id = jobs.repository_id)
    """)

    execute("""
    UPDATE pr_publications
    SET base_branch = (
      SELECT default_branch FROM repositories
      WHERE repositories.id = COALESCE(
        pr_publications.repository_id,
        (SELECT repository_id FROM jobs WHERE jobs.id = pr_publications.job_id)
      )
    )
    """)

    execute("""
    UPDATE collection_runs
    SET base_branch = (SELECT default_branch FROM repositories WHERE repositories.id = collection_runs.repository_id)
    """)
  end

  def down do
    alter table(:collection_runs) do
      remove :base_branch
      remove :base_override
    end

    alter table(:pr_publications) do
      remove :base_branch
    end

    alter table(:jobs) do
      remove :base_branch
    end

    alter table(:approvals) do
      remove :base_branch
      remove :base_override
    end

    alter table(:repositories) do
      remove :integration_branches
      remove :github_branch_names
      remove :github_branches_checked_at
    end
  end
end
