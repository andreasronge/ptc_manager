defmodule PtcManager.Repo.Migrations.ProjectNativeIssueDependencies do
  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :github_state_reason, :string
    end

    drop_if_exists unique_index(:issue_dependencies, [:issue_id, :blocking_issue_number])

    alter table(:issue_dependencies) do
      add :blocking_repository_id, references(:repositories, on_delete: :nilify_all)
      add :blocking_repository_full_name, :string
      add :blocking_github_id, :integer
      add :blocking_node_id, :string
      add :blocking_title, :string
      add :blocking_html_url, :string
      add :blocking_state, :string
      add :blocking_state_reason, :string
    end

    # Existing edges were inferred from issue-body prose. They are not valid
    # native GitHub relationship projections, so invalidate them fail-closed
    # until the next successful GraphQL synchronization rebuilds the edges.
    execute("DELETE FROM issue_dependencies")
    execute("UPDATE issues SET dependencies_projected = 0")

    create unique_index(
             :issue_dependencies,
             [:issue_id, :blocking_repository_full_name, :blocking_issue_number],
             name: :issue_dependencies_exact_blocker_index
           )

    create index(:issue_dependencies, [:blocking_repository_id])
  end

  def down do
    drop_if_exists index(:issue_dependencies, [:blocking_repository_id])
    drop_if_exists index(:issue_dependencies, [], name: :issue_dependencies_exact_blocker_index)

    # Cross-repository edges may legitimately repeat an issue number. The old
    # schema cannot represent that safely, so discard the projection and let
    # the previous synchronizer rebuild it rather than failing rollback.
    execute("DELETE FROM issue_dependencies")
    execute("UPDATE issues SET dependencies_projected = 0")

    alter table(:issue_dependencies) do
      remove :blocking_repository_id
      remove :blocking_repository_full_name
      remove :blocking_github_id
      remove :blocking_node_id
      remove :blocking_title
      remove :blocking_html_url
      remove :blocking_state
      remove :blocking_state_reason
    end

    create unique_index(:issue_dependencies, [:issue_id, :blocking_issue_number])

    alter table(:issues) do
      remove :github_state_reason
    end
  end
end
