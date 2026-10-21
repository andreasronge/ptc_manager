defmodule PtcManager.Repo.Migrations.AddJobDispatchBlockedReason do
  use Ecto.Migration

  # Why a queued job has not been leased: a gate reason for its repository or
  # the error that stopped dispatch before the lease. Written only while the
  # job is queued; a lease or a cancel clears it.
  def change do
    alter table(:jobs) do
      add :dispatch_blocked_reason, :string
      add :dispatch_blocked_at, :utc_datetime_usec
    end
  end
end
