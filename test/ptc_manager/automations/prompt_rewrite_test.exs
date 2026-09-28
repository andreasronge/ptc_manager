defmodule PtcManager.Automations.PromptRewriteTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Automations
  alias PtcManager.Automations.{DefinitionVersion, PromptRewrite}
  alias PtcManager.Repo

  test "rewrites only built-in versions that still carry the old sentence, and back" do
    repository = repository_fixture()
    :ok = Automations.ensure_defaults(repository)
    {:ok, version} = Automations.current_version(repository, "repair_pr")
    assert version.created_by == "system:built-in"

    old = "validate the repair with the repository's own checks"
    new = "validate the repair with the repository's checks and hooks"
    assert version.prompt =~ old

    # A maintainer's own version of the same prompt, carrying the old sentence.
    edited =
      version
      |> Ecto.put_meta(state: :built)
      |> Map.merge(%{
        id: nil,
        version: version.version + 1,
        created_by: "maintainer",
        prompt: "For x: " <> old <> " but my own words"
      })
      |> Repo.insert!()

    assert PromptRewrite.rewrite_built_in(Repo, "repair_pr", old, new) == 1
    assert Repo.get!(DefinitionVersion, version.id).prompt =~ new
    refute Repo.get!(DefinitionVersion, version.id).prompt =~ old
    assert Repo.get!(DefinitionVersion, edited.id).prompt =~ old, "an edited prompt is left alone"

    assert PromptRewrite.rewrite_built_in(Repo, "repair_pr", old, new) == 0
    assert PromptRewrite.rewrite_built_in(Repo, "prepare_issue", old, new) == 0

    assert PromptRewrite.rewrite_built_in(Repo, "repair_pr", new, old) == 1
    assert Repo.get!(DefinitionVersion, version.id).prompt =~ old
  end

  test "dependency guidance migration updates built-ins and preserves edited versions" do
    repository = repository_fixture()
    :ok = Automations.ensure_defaults(repository)
    guidance = "When another issue is the only obstacle, record a native blocked-by relation"

    for key <- ["prepare_issue", "review_issue"] do
      {:ok, version} = Automations.current_version(repository, key)

      old_prompt =
        String.replace(
          version.prompt,
          ~r/When another issue is the only obstacle,.*?Use `ptc:blocked` only for a hold no issue captures\. /,
          ""
        )

      version |> DefinitionVersion.changeset(%{prompt: old_prompt}) |> Repo.update!()

      version
      |> Ecto.put_meta(state: :built)
      |> Map.merge(%{
        id: nil,
        version: version.version + 1,
        created_by: "maintainer",
        prompt: old_prompt
      })
      |> Repo.insert!()
    end

    migration = PtcManager.Repo.Migrations.DistinguishIssueDependenciesFromHolds

    unless Code.ensure_loaded?(migration) do
      Code.require_file(
        "priv/repo/migrations/20260927090000_distinguish_issue_dependencies_from_holds.exs"
      )
    end

    assert :ok = Ecto.Migrator.down(Repo, 20_260_927_090_000, migration, log: false)
    assert :ok = Ecto.Migrator.up(Repo, 20_260_927_090_000, migration, log: false)

    for key <- ["prepare_issue", "review_issue"] do
      definition = Automations.get_definition(repository, key)

      versions =
        Repo.all(
          from version in DefinitionVersion,
            where: version.automation_definition_id == ^definition.id
        )

      assert Enum.find(versions, &(&1.created_by == "system:built-in")).prompt =~ guidance
      refute Enum.find(versions, &(&1.created_by == "maintainer")).prompt =~ guidance
    end
  end
end
