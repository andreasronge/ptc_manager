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
end
