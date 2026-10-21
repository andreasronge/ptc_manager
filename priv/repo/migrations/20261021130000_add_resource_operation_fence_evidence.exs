defmodule PtcManager.Repo.Migrations.AddResourceOperationFenceEvidence do
  use Ecto.Migration

  # On a host without containment an uncertain operation stays fenced until a
  # maintainer releases it; this is what the broker last saw of it.
  def change do
    alter table(:resource_operations) do
      add :fence_evidence, :map
    end
  end
end
