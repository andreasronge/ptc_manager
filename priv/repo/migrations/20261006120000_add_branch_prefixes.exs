defmodule PtcManager.Repo.Migrations.AddBranchPrefixes do
  use Ecto.Migration

  # Every repository and job so far used `ptc-manager/`, so that is what each
  # one stores, including queued jobs whose branch is not named yet.
  def up do
    alter table(:repositories) do
      add :branch_prefixes, :map, default: %{"default" => "ptc-manager/", "mappings" => []}
    end

    alter table(:jobs) do
      add :branch_prefix, :string, null: false, default: "ptc-manager/"
    end

    flush()

    execute("""
    UPDATE repositories
    SET branch_prefixes = '{"default":"ptc-manager/","mappings":[]}'
    WHERE branch_prefixes IS NULL
    """)
  end

  def down do
    alter table(:jobs) do
      remove :branch_prefix
    end

    alter table(:repositories) do
      remove :branch_prefixes
    end
  end
end
