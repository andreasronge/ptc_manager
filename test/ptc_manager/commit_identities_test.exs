defmodule PtcManager.CommitIdentitiesTest do
  use PtcManager.DataCase, async: false
  alias PtcManager.{AgentEnvironmentVariables, CommitIdentities}
  alias PtcManager.Operations.CommitIdentity

  test "owner overrides are case-insensitive and fall back to the editable default" do
    repository = repository_fixture(%{github_owner: "TyraOrg"})
    other = repository_fixture()
    assert {:ok, default} = CommitIdentities.resolve(other)
    assert CommitIdentities.source(default) == "default"

    assert {:ok, override} =
             CommitIdentities.put(
               %{owner: "TYRAORG", name: "Owner Agent", email: "owner@example.test"},
               "maintainer"
             )

    assert {:ok, ^override} = CommitIdentities.resolve(repository)
    assert CommitIdentities.source(override) == "owner override: tyraorg"
    assert {:ok, ^default} = CommitIdentities.resolve(other)
    assert {:ok, _} = CommitIdentities.delete("tyraorg", "maintainer")
    assert {:ok, ^default} = CommitIdentities.resolve(repository)

    assert {:ok, _} =
             CommitIdentities.put(
               %{owner: "", name: "New Default", email: "new@example.test"},
               "maintainer"
             )

    assert {:ok, %{name: "New Default"}} = CommitIdentities.resolve(repository)
    assert length(CommitIdentities.list()) == 1
    assert {:ok, _} = CommitIdentities.delete("", "maintainer")
    assert {:error, reason} = CommitIdentities.resolve(repository)
    assert reason =~ "No agent commit identity"
  end

  test "configured identity wins over repository variables for all four Git names" do
    repository = repository_fixture()

    for name <- ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL) do
      assert {:ok, _} =
               AgentEnvironmentVariables.put(
                 repository.id,
                 %{"name" => name, "value" => "untrusted"},
                 "maintainer"
               )
    end

    assert {:ok, variables} = CommitIdentities.environment(repository.id)

    assert Map.new(variables, &{&1.name, &1.value}) == %{
             "GIT_AUTHOR_NAME" => "Test Agent",
             "GIT_AUTHOR_EMAIL" => "agent@example.test",
             "GIT_COMMITTER_NAME" => "Test Agent",
             "GIT_COMMITTER_EMAIL" => "agent@example.test"
           }
  end

  test "invalid settings cannot replace a usable identity" do
    repository = repository_fixture()

    for attrs <- [
          %{owner: "", name: "", email: "a@b"},
          %{owner: "", name: "bad\nname", email: "a@b"},
          %{owner: "", name: "<>", email: "a@b"},
          %{owner: "", name: "Agent", email: "invalid"},
          %{owner: "", name: "Agent", email: "a\0@b"},
          %{owner: nil, name: "Agent", email: "a@b"},
          %{owner: "owner/repo", name: "Agent", email: "a@b"}
        ] do
      assert {:error, %Ecto.Changeset{}} = CommitIdentities.put(attrs, "maintainer")
    end

    assert {:ok, %{name: "Test Agent"}} = CommitIdentities.resolve(repository)
    assert Repo.aggregate(CommitIdentity, :count) == 1
  end
end
