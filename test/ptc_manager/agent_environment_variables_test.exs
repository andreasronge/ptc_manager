defmodule PtcManager.AgentEnvironmentVariablesTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.AgentEnvironmentVariables
  alias PtcManager.Operations.{AgentEnvironmentVariable, AuditEvent}
  alias PtcManager.Repo

  test "encrypts values at rest and replaces a repository variable" do
    repository = repository_fixture()

    assert {:ok, variable} =
             AgentEnvironmentVariables.put(
               repository.id,
               %{
                 "name" => "OPENROUTER_API_KEY",
                 "value" => "first-secret"
               },
               "maintainer"
             )

    assert variable.value == "first-secret"

    %{rows: [[stored]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT value FROM agent_environment_variables WHERE id = ?",
        [variable.id]
      )

    refute stored =~ "first-secret"

    assert {:ok, replaced} =
             AgentEnvironmentVariables.put(
               repository.id,
               %{
                 "name" => "OPENROUTER_API_KEY",
                 "value" => "rotated-secret"
               },
               "maintainer"
             )

    assert replaced.id == variable.id
    assert [%{value: "rotated-secret"}] = AgentEnvironmentVariables.list(repository.id)

    audits = Repo.all(from audit in AuditEvent, order_by: audit.id)

    assert Enum.map(audits, &{&1.actor, &1.action, &1.target_id, &1.details}) == [
             {"maintainer", "repository.agent_environment_variable_added", repository.id,
              %{"name" => "OPENROUTER_API_KEY"}},
             {"maintainer", "repository.agent_environment_variable_rotated", repository.id,
              %{"name" => "OPENROUTER_API_KEY"}}
           ]

    refute inspect(audits) =~ "first-secret"
    refute inspect(audits) =~ "rotated-secret"
  end

  test "accepts the specified grammar and rejects only reserved prefixes and names" do
    repository = repository_fixture()

    for name <- ["A", "_PRIVATE", "OPENROUTER_API_KEY", "X9"] do
      assert {:ok, _variable} =
               AgentEnvironmentVariables.put(
                 repository.id,
                 %{"name" => name, "value" => "v"},
                 "maintainer"
               )
    end

    for name <- [
          "lower",
          "9START",
          "HAS-DASH",
          "TOKEN\n",
          "PATH",
          "HOME",
          "CODEX_HOME",
          "PTC_X",
          "HERDR_X"
        ] do
      assert {:error, changeset} =
               AgentEnvironmentVariables.put(
                 repository.id,
                 %{"name" => name, "value" => "v"},
                 "maintainer"
               )

      assert changeset.errors[:name]
    end
  end

  test "deleting is scoped to the repository" do
    first = repository_fixture()
    second = repository_fixture()

    {:ok, variable} =
      AgentEnvironmentVariables.put(
        first.id,
        %{"name" => "TOKEN", "value" => "secret"},
        "maintainer"
      )

    assert {:error, :not_found} =
             AgentEnvironmentVariables.delete(second.id, variable.id, "maintainer")

    assert Repo.get!(AgentEnvironmentVariable, variable.id)

    assert {:ok, _variable} =
             AgentEnvironmentVariables.delete(first.id, variable.id, "maintainer")

    refute Repo.get(AgentEnvironmentVariable, variable.id)

    assert %{actor: "maintainer", details: %{"name" => "TOKEN"}} =
             Repo.get_by!(AuditEvent,
               action: "repository.agent_environment_variable_deleted",
               target_id: first.id
             )
  end
end
