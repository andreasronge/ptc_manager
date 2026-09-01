defmodule PtcManager.ManagerTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.CommandEnvironment
  alias PtcManager.Manager
  alias PtcManager.Operations.{Issue, Proposal}
  alias PtcManager.Repo

  defmodule FakeAdapter do
    def analyze(_issue) do
      {:ok,
       %{
         "plain_summary" => "A simple private explanation.",
         "why_it_matters" => "It helps maintainers choose the next step.",
         "scope" => "small",
         "risk" => "low",
         "readiness" => "ready",
         "technical_evidence" => "lib/example.ex contains the affected boundary."
       }}
    end
  end

  test "stores private analysis as a proposal without changing the issue" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{body: "Untrusted issue text"})

    assert {:ok, analysis} = FakeAdapter.analyze(issue)
    assert {:ok, proposal} = Manager.store_analysis(issue, analysis)
    assert proposal.plain_summary == "A simple private explanation."
    assert proposal.source_digest == issue.content_digest
    assert Repo.aggregate(Proposal, :count) == 1
    assert Repo.get!(Issue, issue.id) == issue
  end

  test "scrubs application secrets from child-process environments" do
    environment = %{
      "PATH" => "/usr/bin",
      "HOME" => "/var/lib/ptc_manager",
      "GITHUB_READ_TOKEN" => "github-secret",
      "PTC_MANAGER_PASSWORD" => "password-secret",
      "SECRET_KEY_BASE" => "signing-secret",
      "DATABASE_PATH" => "/secret/database"
    }

    child_environment = environment |> CommandEnvironment.scrub() |> Map.new()

    assert child_environment["PATH"] == "/usr/bin"
    assert child_environment["HOME"] == "/var/lib/ptc_manager"
    assert child_environment["GITHUB_READ_TOKEN"] == nil
    assert child_environment["PTC_MANAGER_PASSWORD"] == nil
    assert child_environment["SECRET_KEY_BASE"] == nil
    assert child_environment["DATABASE_PATH"] == nil

    assert {"/usr/bin/sudo", ["-n", "-H", "-u", "codex-user", "--", "/bin/codex", "exec"]} =
             CommandEnvironment.command("/bin/codex", ["exec"], "codex-user")
  end
end
