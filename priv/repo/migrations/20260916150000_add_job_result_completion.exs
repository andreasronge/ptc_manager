defmodule PtcManager.Repo.Migrations.AddJobResultCompletion do
  use Ecto.Migration

  # Reported completion material, stored beside the verified Git result it was
  # accepted for. It is evidence, never a publication gate, so it is nullable
  # and carries its own outcome rather than being inferred from being absent.
  def change do
    alter table(:jobs) do
      add :result_completion, :map
    end
  end
end
