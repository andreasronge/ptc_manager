defmodule PtcManager.Repo.Migrations.AddMaintainerLabels do
  use Ecto.Migration

  def change do
    alter table(:issues) do
      add :github_labels, :map, default: %{"names" => []}
    end

    alter table(:repositories) do
      add :maintainer_labels, :map, default: %{"labels" => []}
    end
  end
end
