defmodule PtcManager.ExecutionProfilesTest do
  use PtcManager.DataCase, async: false
  alias PtcManager.ExecutionProfiles

  test "ux is available alongside the scope and risk presets" do
    assert Enum.map(ExecutionProfiles.list(), & &1.name) == ~w(small standard strong ux)
    ux = List.last(ExecutionProfiles.list())
    assert {ux.kind, ux.model, ux.effort} == {"claude", "claude-opus-5-5", "high"}

    assert {ux.reviewer_kind, ux.reviewer_model, ux.max_reviews, ux.review_timeout_ms} ==
             {"codex", "gpt-6.1-sol", 2, 900_000}
  end

  test "label routing, overrides and conflicts freeze identically for all approval modes" do
    put_agent_profiles(%{"codex" => %{"enabled" => true}, "claude" => %{"enabled" => true}})
    repository = repository_fixture(%{auto_fix_issues: true, auto_fix_daily_limit: 50})

    {:ok, repository} =
      PtcManager.Operations.add_execution_profile_mapping(
        repository.id,
        "design",
        "ux",
        "maintainer"
      )

    {:ok, repository} =
      PtcManager.Operations.add_execution_profile_mapping(
        repository.id,
        "urgent",
        "strong",
        "maintainer"
      )

    for mode <- [:manual, :direct, :automatic],
        {labels, override, expected} <- [
          {["DESIGN", "unmapped"], nil, "ux"},
          {["design"], "small", "small"},
          {["design", "urgent"], nil, "standard"}
        ] do
      issue =
        issue_fixture(repository, %{
          github_labels: %{"names" => labels},
          workflow_label: "ptc:ready"
        })

      if mode == :manual, do: proposal_fixture(issue, %{scope: "medium", risk: "medium"})

      result =
        case mode do
          :manual ->
            PtcManager.Operations.approve_issue(issue.id, "maintainer", nil, override)

          :direct ->
            PtcManager.Operations.approve_issue_directly(issue.id, "maintainer", nil, override)

          :automatic ->
            PtcManager.Operations.auto_approve_issue(issue.id)
        end

      assert {:ok, job} = result
      expected = if mode == :automatic and override, do: "ux", else: expected
      assert job.execution_settings["name"] == expected
      if expected == "ux", do: assert(job.required_review_count == 2)

      {:ok, _} =
        issue
        |> PtcManager.Operations.Issue.changeset(%{github_labels: %{"names" => []}})
        |> Repo.update()

      assert Repo.get!(PtcManager.Operations.Job, job.id).execution_settings ==
               job.execution_settings
    end

    issue = issue_fixture(repository, %{github_labels: %{"names" => ["design"]}})
    {:ok, job} = PtcManager.Operations.approve_issue_directly(issue.id, "maintainer")

    {:ok, _} =
      PtcManager.Operations.remove_execution_profile_mapping(
        repository.id,
        "design",
        "maintainer"
      )

    assert Repo.get!(PtcManager.Operations.Job, job.id).execution_settings["name"] == "ux"
  end

  test "mapping validation, resolution and repository transfer" do
    alias PtcManager.Repository.ExecutionProfileMappings, as: Mappings
    alias PtcManager.Operations.Repository
    repository = repository_fixture()
    assert {:ok, nil} = Mappings.resolve(repository, ["ux"])
    assert {:error, :invalid_execution_profile} = Mappings.add(repository, "design", "other")
    assert {:error, :reserved_label_name} = Mappings.add(repository, "ptc:ready", "ux")
    assert {:error, :invalid_label_name} = Mappings.add(repository, "", "ux")

    {:ok, repository} =
      PtcManager.Operations.add_execution_profile_mapping(
        repository.id,
        "design",
        "ux",
        "maintainer"
      )

    assert {:error, :label_already_mapped} = Mappings.add(repository, "DESIGN", "small")

    {:ok, repository} =
      PtcManager.Operations.add_execution_profile_mapping(
        repository.id,
        "canvas",
        "ux",
        "maintainer"
      )

    assert {:ok, "ux"} = Mappings.resolve(repository, ["DESIGN", "canvas"])

    {:ok, repository} =
      PtcManager.Operations.add_execution_profile_mapping(
        repository.id,
        "urgent",
        "strong",
        "maintainer"
      )

    assert {:error, mappings} = Mappings.resolve(repository, ["design", "urgent"])
    assert Enum.map(mappings, & &1["label"]) == ["design", "urgent"]
    mappings = for n <- 1..20, do: %{"label" => "label#{n}", "profile" => "ux"}
    full = %{repository | execution_profile_mappings: %{"mappings" => mappings}}
    assert {:error, :too_many_mappings} = Mappings.add(full, "extra", "ux")

    for invalid <- [
          nil,
          %{},
          %{"mappings" => [nil]},
          %{"mappings" => [%{"label" => "design", "profile" => "bad"}]},
          %{"mappings" => mappings ++ mappings},
          %{
            "mappings" => [
              %{"label" => "design", "profile" => "ux"},
              %{"label" => "DESIGN", "profile" => "small"}
            ]
          }
        ] do
      refute Repository.changeset(repository, %{execution_profile_mappings: invalid}).valid?
    end

    settings = PtcManager.Cluster.RepositorySettings.export(repository)

    assert settings["settings"]["execution_profile_mappings"] ==
             repository.execution_profile_mappings

    target = %{repository | execution_profile_mappings: %{"mappings" => []}}

    assert :ok =
             PtcManager.Cluster.RepositorySettings.import(settings, target, %{
               actor: "maintainer",
               source: "source",
               checks: %{}
             })

    assert Repo.get!(Repository, repository.id).execution_profile_mappings ==
             repository.execution_profile_mappings
  end
end
