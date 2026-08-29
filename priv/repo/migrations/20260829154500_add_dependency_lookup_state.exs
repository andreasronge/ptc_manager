defmodule PtcManager.Repo.Migrations.AddDependencyLookupState do
  use Ecto.Migration

  def change do
    alter table(:issue_dependencies) do
      add :lookup_state, :string, null: false, default: "pending"
      add :lookup_checked_at, :utc_datetime_usec
    end
  end
end
