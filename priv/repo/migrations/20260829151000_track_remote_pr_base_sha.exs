defmodule PtcManager.Repo.Migrations.TrackRemotePrBaseSha do
  use Ecto.Migration

  def change do
    alter table(:pr_publications) do
      add :remote_base_sha, :string
    end
  end
end
