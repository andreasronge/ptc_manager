defmodule PtcManager.Repo.Migrations.AddResourceOperationRemainingProcesses do
  use Ecto.Migration

  # What a wrapper reported when its command left processes behind. It is
  # evidence for the maintainer who releases the slot, so recovery notes in
  # last_error must not replace it.
  def change do
    alter table(:resource_operations) do
      add :remaining_processes, :map
    end
  end
end
