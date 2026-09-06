defmodule PtcManager.Repo.Migrations.AddAutoFixIssues do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :auto_fix_issues, :boolean, null: false, default: false
    end
  end
end
