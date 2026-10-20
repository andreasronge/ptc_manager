defmodule PtcManager.ClusterMember do
  @moduledoc "Runs on a `:peer` cluster member in the multi-member integration tests."

  @doc "Migrates the member's own database before the application starts."
  def migrate do
    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(PtcManager.Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))

    :ok
  end
end
