defmodule PtcManager.Repo.Migrations.RemoveImplementationTestCommand do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      remove :implementation_test_command, :text
    end
  end
end
