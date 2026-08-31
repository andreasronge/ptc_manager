defmodule PtcManager.Repo.Migrations.AddWorkerSnapshotIdentity do
  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :worker_incarnation_id, :string
      add :previous_worker_incarnation_id, :string
      add :herdr_incarnation_id, :string
      add :previous_herdr_incarnation_id, :string
      add :snapshot_sequence, :integer, null: false, default: 0
      add :healthy_snapshot_count, :integer, null: false, default: 0
      add :restart_reason, :string
      add :incarnation_changed_at, :utc_datetime_usec
    end
  end
end
