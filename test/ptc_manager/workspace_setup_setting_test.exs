defmodule PtcManager.WorkspaceSetupSettingTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.{AuditEvent, Repository}
  alias PtcManager.Repository.Health

  test "saves a trimmed command and timeout and records who changed it" do
    repository = repository_fixture()

    assert {:ok, updated} =
             Operations.update_workspace_setup(repository.id, "  deno install  ", 15, "andreas")

    assert updated.workspace_setup_command == "deno install"
    assert updated.workspace_setup_timeout_minutes == 15

    audit = Repo.get_by!(AuditEvent, action: "repository.workspace_setup_changed")
    assert audit.details["command"] == "deno install"
    assert audit.details["timeout_minutes"] == 15
  end

  test "refuses a blank or multi-line command and an out-of-range timeout" do
    repository = repository_fixture()

    for {command, timeout} <- [
          {"", 10},
          {"deno install\nrm -rf /", 10},
          {"deno install", 0},
          {"deno install", 1441},
          {"deno install", nil},
          {String.duplicate("x", 2_001), 10}
        ] do
      assert {:error, :invalid_workspace_setup} =
               Operations.update_workspace_setup(repository.id, command, timeout, "andreas")
    end

    assert Repo.get!(Repository, repository.id).workspace_setup_command ==
             "./scripts/ptc/bootstrap"
  end

  test "a repository without a setup command needs attention" do
    repository =
      repository_fixture(%{workspace_setup_command: nil, workspace_setup_timeout_minutes: nil})

    summary = Health.summarize(repository)
    assert summary.workspace_setup.status == :attention
    assert summary.workspace_setup.label == "Workspace setup missing"
    assert Health.overall(summary) == :attention

    configured = Health.summarize(repository_fixture())
    assert configured.workspace_setup.status == :ready
    assert configured.workspace_setup.detail == "./scripts/ptc/bootstrap · up to 10 min"
  end

  test "onboarding leaves the setup for the maintainer to choose" do
    assert {:ok, repository} =
             Operations.onboard_repository(%{
               github_owner: "tyraorg",
               github_name: "api",
               default_branch: "develop"
             })

    assert is_nil(repository.workspace_setup_command)
    assert is_nil(repository.workspace_setup_timeout_minutes)
  end
end
