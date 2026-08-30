defmodule PtcManager.ManagerTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Manager
  alias PtcManager.Manager.{CodexAdapter, Gate}
  alias PtcManager.Operations.{Issue, Proposal}
  alias PtcManager.Repo

  defmodule FakeAdapter do
    @behaviour PtcManager.Manager.Adapter

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

    assert {:ok, proposal} = Manager.investigate_issue(issue.id, adapter: FakeAdapter)
    assert proposal.plain_summary == "A simple private explanation."
    assert proposal.source_digest == issue.content_digest
    assert Repo.aggregate(Proposal, :count) == 1
    assert Repo.get!(Issue, issue.id) == issue
  end

  test "does not investigate a closed issue" do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{state: "closed"})

    assert {:error, :issue_closed} = Manager.investigate_issue(issue.id, adapter: FakeAdapter)
    assert Repo.aggregate(Proposal, :count) == 0
  end

  test "scrubs application secrets from the Codex child environment" do
    environment = %{
      "PATH" => "/usr/bin",
      "HOME" => "/var/lib/ptc_manager",
      "GITHUB_READ_TOKEN" => "github-secret",
      "PTC_MANAGER_PASSWORD" => "password-secret",
      "SECRET_KEY_BASE" => "signing-secret",
      "DATABASE_PATH" => "/secret/database"
    }

    child_environment = environment |> CodexAdapter.command_environment() |> Map.new()

    assert child_environment["PATH"] == "/usr/bin"
    assert child_environment["HOME"] == "/var/lib/ptc_manager"
    assert child_environment["GITHUB_READ_TOKEN"] == nil
    assert child_environment["PTC_MANAGER_PASSWORD"] == nil
    assert child_environment["SECRET_KEY_BASE"] == nil
    assert child_environment["DATABASE_PATH"] == nil
    assert File.regular?(CodexAdapter.schema_path())

    assert {"/usr/bin/sudo", ["-n", "-H", "-u", "codex-user", "--", "/bin/codex", "exec"]} =
             CodexAdapter.codex_command("/bin/codex", ["exec"], "codex-user")
  end

  test "classifies Codex failures without retaining untrusted prompt text" do
    output = """
    <issue_data>
    ERROR: secret issue text that must not be retained
    invalid_json_schema
    </issue_data>
    Error: runtime initialization failed
    """

    assert CodexAdapter.codex_exit_error(1, output) ==
             {:codex_exit, 1, :codex_process_failed}
  end

  test "permits only one process-wide manager investigation" do
    assert {:ok, lease} = Gate.checkout()
    assert {:error, :manager_busy} = Gate.checkout()
    assert :ok = Gate.checkin(lease)
    assert {:ok, next_lease} = Gate.checkout()
    assert :ok = Gate.checkin(next_lease)
  end
end
