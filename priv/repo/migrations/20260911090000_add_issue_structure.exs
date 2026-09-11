defmodule PtcManager.Repo.Migrations.AddIssueStructure do
  use Ecto.Migration

  @moduledoc """
  Projects GitHub's parent and sub-issue relations onto synchronized issues.

  `structure_projected` starts false, so every guard treats an issue written
  before this migration as unknown until the next synchronization, exactly as
  `dependencies_projected` did.
  """

  def change do
    alter table(:issues) do
      add :parent_issue_number, :integer
      add :sub_issues, :map, null: false, default: %{"nodes" => [], "total" => 0}
      add :structure_projected, :boolean, null: false, default: false
    end

    create index(:issues, [:repository_id, :parent_issue_number])
  end
end
