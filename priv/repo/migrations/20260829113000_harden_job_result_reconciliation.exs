defmodule PtcManager.Repo.Migrations.HardenJobResultReconciliation do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :result_checked_at, :utc_datetime_usec
      add :result_attempt_token, :string
      add :result_attempt_expires_at, :utc_datetime_usec
    end

    create index(:jobs, [:state, :result_checked_at], name: :jobs_result_reconciliation_queue)
  end
end
