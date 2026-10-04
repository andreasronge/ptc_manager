defmodule PtcManager.Repo.Migrations.AddAutoFixDailyLimit do
  use Ecto.Migration

  def change do
    alter table(:repositories) do
      add :auto_fix_daily_limit, :integer, null: false, default: 5
    end
  end
end
