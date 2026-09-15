defmodule PtcManager.Repo.Migrations.AddObservedHeadShaToPrPublications do
  use Ecto.Migration

  # The head GitHub last reported for a publication blocked on a head PtcManager
  # never verified. Recording it lets the block announce itself once instead of
  # on every poll; `remote_head_sha` stays the verified head.
  def change do
    alter table(:pr_publications) do
      add :observed_head_sha, :string
    end
  end
end
