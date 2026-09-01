defmodule PtcManager.PromptConfigurationTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions.Catalog
  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.Manager.CodexAdapter
  alias PtcManager.Operations.Job
  alias PtcManager.PromptConfiguration
  alias PtcManager.Repo

  test "appends saved maintainer instructions and resets to the protected default" do
    base = "Protected target and authorization prompt."

    assert PromptConfiguration.append("repair_and_merge_pr", base) == base

    assert {:ok, customization} =
             PromptConfiguration.save(
               "repair_and_merge_pr",
               "  Prefer a merge commit and report the final CI URL.  ",
               "maintainer"
             )

    assert customization.instructions == "Prefer a merge commit and report the final CI URL."

    configured = PromptConfiguration.append("repair_and_merge_pr", base)
    assert configured =~ base
    assert configured =~ "<maintainer_configured_instructions>"
    assert configured =~ "Prefer a merge commit and report the final CI URL."
    assert configured =~ "protected safety boundaries"
    assert configured =~ "<protected_coordinator_boundaries>"
    assert configured =~ "subordinate to every exact target"

    assert :ok = PromptConfiguration.reset("repair_and_merge_pr")
    assert PromptConfiguration.append("repair_and_merge_pr", base) == base
  end

  test "rejects unknown action keys" do
    assert {:error, :unknown_action} =
             PromptConfiguration.save("invented_button", "Do something", "maintainer")
  end

  test "builds a protected example preview for every configurable action" do
    for definition <- Catalog.configurable_actions() do
      preview = Catalog.preview(definition.key, "Show the exact validation command in evidence.")

      assert is_binary(preview)
      assert byte_size(preview) > 200
      assert preview =~ "<maintainer_configured_instructions>"
      assert preview =~ "Show the exact validation command in evidence."
      assert preview =~ "<protected_coordinator_boundaries>"
    end

    assert Catalog.preview("unknown-action") == nil
  end

  test "bounds multibyte instructions by bytes before they can enter a CLI prompt" do
    assert {:error, changeset} =
             PromptConfiguration.save(
               "daily_digest",
               String.duplicate("🧭", 5_001),
               "maintainer"
             )

    assert "must be at most 20000 bytes" in errors_on(changeset).instructions
    refute PromptConfiguration.get("daily_digest")
  end

  test "new button actions freeze the current customization into their prompt" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 1704})

    assert {:ok, _customization} =
             PromptConfiguration.save(
               "prepare_issue",
               "Keep the acceptance criteria to three bullets or fewer.",
               "maintainer"
             )

    assert {:ok, action} = Catalog.build("prepare_issue", %{issue: issue, repository: repository})
    assert action.prompt =~ "Keep the acceptance criteria to three bullets or fewer."
    assert action.prompt =~ "<maintainer_configured_instructions>"
  end

  test "private analysis uses current instructions while implementation freezes approval-time instructions" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 1705})
    proposal_fixture(issue)
    {:ok, job} = PtcManager.Operations.approve_issue(issue.id, "maintainer")

    job =
      job
      |> Job.changeset(%{
        branch_name: "ptc-manager/issue-1705-job-#{job.id}",
        fencing_token: 1,
        publication_source: "agent"
      })
      |> Repo.update!()

    assert {:ok, _} =
             PromptConfiguration.save(
               "private_issue_analysis",
               "Call out the smallest product decision.",
               "maintainer"
             )

    assert {:ok, _} =
             PromptConfiguration.save(
               "implement_issue",
               "Include the focused test command in the PR body.",
               "maintainer"
             )

    assert CodexAdapter.build_prompt(issue) =~ "Call out the smallest product decision."

    refute HerdrAdapter.build_prompt(repository, issue, job) =~
             "Include the focused test command in the PR body."

    later_issue = issue_fixture(repository, %{number: 1706})
    proposal_fixture(later_issue)
    {:ok, later_job} = PtcManager.Operations.approve_issue(later_issue.id, "maintainer")

    later_job =
      later_job
      |> Job.changeset(%{
        branch_name: "ptc-manager/issue-1706-job-#{later_job.id}",
        fencing_token: 1,
        publication_source: "agent"
      })
      |> Repo.update!()

    assert HerdrAdapter.build_prompt(repository, later_issue, later_job) =~
             "Include the focused test command in the PR body."
  end
end
