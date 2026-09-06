defmodule PtcManager.RepoTransactionMultiTest do
  use PtcManager.DataCase, async: false
  alias PtcManager.RepoTransaction

  test "multi busy errors return a tagged error and roll back earlier writes" do
    repository = repository_fixture()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:repository, Ecto.Changeset.change(repository, enabled: false))
      |> Ecto.Multi.run(:contention, fn _repo, _changes ->
        raise Exqlite.Error, message: "Database busy", statement: "UPDATE repositories"
      end)

    assert {:error, :database_busy} = RepoTransaction.immediate(multi)
    assert Repo.reload!(repository).enabled
  end

  test "multi preserves named step failures and successful results" do
    multi =
      Ecto.Multi.new() |> Ecto.Multi.run(:step, fn _repo, _changes -> {:error, :unavailable} end)

    assert {:error, :step, :unavailable, %{}} = RepoTransaction.immediate(multi)
    assert {:ok, %{}} = RepoTransaction.immediate(Ecto.Multi.new())
  end
end
