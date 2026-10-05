defmodule PtcManager.Repo.Migrations.AddGithubDefaultBranch do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :github_default_branch, :string
    end
  end
end
